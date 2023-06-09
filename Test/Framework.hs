{- git-annex test suite framework
 -
 - Copyright 2010-2022 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Test.Framework where

import Test.Tasty
import Test.Tasty.Runners
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck
import Test.Tasty.Options
import Test.Tasty.Ingredients.Rerun
import Test.Tasty.Ingredients.ConsoleReporter
import Options.Applicative.Types
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import System.Environment (getArgs)
import System.Console.Concurrent
import System.Console.ANSI
import GHC.Conc

import Common
import Types.Test
import Types.Concurrency

import qualified Annex
import qualified Annex.UUID
import qualified Types.RepoVersion
import qualified Backend
import qualified Git.CurrentRepo
import qualified Git.Construct
import qualified Git.Types
import qualified Git.Branch
import qualified Git.Ref
import qualified Types.KeySource
import qualified Types.Backend
import qualified Types
import qualified Remote
import qualified Key
import qualified Types.Key
import qualified Types.Messages
import qualified Config
import qualified Annex.WorkTree
import qualified Annex.Link
import qualified Annex.Path
import qualified Annex.Action
import qualified Annex.AdjustedBranch
import qualified Annex.Init
import qualified Utility.Process
import qualified Utility.Process.Transcript
import qualified Utility.Env
import qualified Utility.Env.Set
import qualified Utility.Exception
import qualified Utility.ThreadScheduler
import qualified Utility.Tmp.Dir
import qualified Utility.Metered
import qualified Command.Uninit

-- Run a process. The output and stderr is captured, and is only
-- displayed if the process does not return the expected value.
testProcess :: String -> [String] -> (Bool -> Bool) -> String -> Assertion
testProcess command params expectedret faildesc = do
	(transcript, ret) <- Utility.Process.Transcript.processTranscript command params Nothing
	(expectedret ret) @? (faildesc ++ " failed (transcript follows)\n" ++ transcript)

-- Run git. (Do not use to run git-annex as the one being tested
-- may not be in path.)
git :: String -> [String] -> String -> Assertion
git command params = testProcess "git" (command:params) (== True)

-- For when git is expected to fail.
git_shouldfail :: String -> [String] -> String -> Assertion
git_shouldfail command params = testProcess "git" (command:params) (== False)

-- Run git-annex.
git_annex :: String -> [String] -> String -> Assertion
git_annex = git_annex' (== True)

-- For when git-annex is expected to fail.
git_annex_shouldfail :: String -> [String] -> String -> Assertion
git_annex_shouldfail = git_annex' (== False)

git_annex' :: (Bool -> Bool) -> String -> [String] -> String -> Assertion
git_annex' expectedret command params faildesc = do
	pp <- Annex.Path.programPath
	testProcess pp (command:params) expectedret faildesc

{- Runs git-annex and returns its standard output. -}
git_annex_output :: String -> [String] -> IO String
git_annex_output command params = do
	pp <- Annex.Path.programPath
	Utility.Process.readProcess pp (command:params)

git_annex_expectoutput :: String -> [String] -> [String] -> Assertion
git_annex_expectoutput command params expected = do
	got <- lines <$> git_annex_output command params
	got == expected @? ("unexpected value running " ++ command ++ " " ++ show params ++ " -- got: " ++ show got ++ " expected: " ++ show expected)

-- Runs an action in the current annex. Note that shutdown actions
-- are not run; this should only be used for actions that query state.
annexeval :: Types.Annex a -> IO a
annexeval a = do
	s <- Annex.new =<< Git.CurrentRepo.get
	Annex.eval s $ do
		Annex.setOutput Types.Messages.QuietOutput
		a `finally` Annex.Action.stopCoProcesses

innewrepo :: IO () -> IO ()
innewrepo a = withgitrepo $ \r -> indir r a

inmainrepo :: IO a -> IO a
inmainrepo a = do
	d <- mainrepodir
	indir d a

with_ssh_origin :: (Assertion -> Assertion) -> (Assertion -> Assertion)
with_ssh_origin cloner a = cloner $ do
	let k = Git.Types.ConfigKey (encodeBS config)
	let v = Git.Types.ConfigValue (toRawFilePath "/dev/null")
	origindir <- absPath . Git.Types.fromConfigValue
		=<< annexeval (Config.getConfig k v)
	let originurl = "localhost:" ++ fromRawFilePath origindir
	git "config" [config, originurl] "git config failed"
	a
  where
	config = "remote.origin.url"

intmpclonerepo :: Assertion -> Assertion
intmpclonerepo a = withtmpclonerepo $ \r -> indir r a

checkRepo :: Types.Annex a -> FilePath -> IO a
checkRepo getval d = do
	s <- Annex.new =<< Git.Construct.fromPath (toRawFilePath d)
	Annex.eval s $
		getval `finally` Annex.Action.stopCoProcesses

intmpbareclonerepo :: Assertion -> Assertion
intmpbareclonerepo a = withtmpclonerepo' (newCloneRepoConfig { bareClone = True } ) $
	\r -> indir r a

intmpsharedclonerepo :: Assertion -> Assertion
intmpsharedclonerepo a = withtmpclonerepo' (newCloneRepoConfig { sharedClone = True } ) $
	\r -> indir r a

withtmpclonerepo :: (FilePath -> Assertion) -> Assertion
withtmpclonerepo = withtmpclonerepo' newCloneRepoConfig

withtmpclonerepo' :: CloneRepoConfig -> (FilePath -> Assertion) -> Assertion
withtmpclonerepo' cfg a = do
	dir <- tmprepodir
	maindir <- mainrepodir
	clone <- clonerepo maindir dir cfg
	r <- tryNonAsync (a clone)
	case r of
		Right () -> return ()
		Left e -> do
			whenM (keepFailures <$> getTestMode) $
				putStrLn $ "** Preserving repo for failure analysis in " ++ clone
			throwM e

disconnectOrigin :: Assertion
disconnectOrigin = git "remote" ["rm", "origin"] "remote rm"

withgitrepo :: (FilePath -> Assertion) -> Assertion
withgitrepo a = do
	maindir <- mainrepodir
	bracket (setuprepo maindir) return a

indir :: FilePath -> IO a -> IO a
indir dir a = do
	currdir <- getCurrentDirectory
	-- Assertion failures throw non-IO errors; catch
	-- any type of error and change back to currdir before
	-- rethrowing.
	r <- bracket_
		(changeToTopDir dir)
		(setCurrentDirectory currdir)
		(tryNonAsync a)
	case r of
		Right v -> return v
		Left e -> throwM e

adjustedbranchsupported :: FilePath -> IO Bool
adjustedbranchsupported repo = indir repo $ Annex.AdjustedBranch.isGitVersionSupported

setuprepo :: FilePath -> IO FilePath
setuprepo dir = do
	cleanup dir
	git "init" ["-q", dir] "git init"
	configrepo dir
	return dir

data CloneRepoConfig = CloneRepoConfig
	{ bareClone :: Bool
	, sharedClone :: Bool
	}

newCloneRepoConfig :: CloneRepoConfig
newCloneRepoConfig = CloneRepoConfig
	{ bareClone = False
	, sharedClone = False
	}

-- clones are always done as local clones; we cannot test ssh clones
clonerepo :: FilePath -> FilePath -> CloneRepoConfig -> IO FilePath
clonerepo old new cfg = do
	cleanup new
	let cloneparams = catMaybes
		[ Just "-q"
		, if bareClone cfg then Just "--bare" else Nothing
		, if sharedClone cfg then Just "--shared" else Nothing
		, Just old
		, Just new
		]
	git "clone" cloneparams "git clone"
	configrepo new
	indir new $ do
		ver <- annexVersion <$> getTestMode
		git_annex "init" 
			[ "-q"
			, new, "--version"
			, show (Types.RepoVersion.fromRepoVersion ver)
			]
			"git annex init"
	unless (bareClone cfg) $
		indir new $
			setupTestMode
	return new

configrepo :: FilePath -> IO ()
configrepo dir = indir dir $ do
	-- ensure git is set up to let commits happen
	git "config" ["user.name", "Test User"]
		"git config"
	git "config" ["user.email", "test@example.com"]
		"git config"
	-- avoid signed commits by test suite
	git "config" ["commit.gpgsign", "false"]
		"git config"
	-- tell git-annex to not annex the ingitfile
	git "config" ["annex.largefiles", "exclude=" ++ ingitfile]
		"git config annex.largefiles"

ensuredir :: FilePath -> IO ()
ensuredir d = do
	e <- doesDirectoryExist d
	unless e $
		createDirectory d
	
{- Prevent global git configs from affecting the test suite. -}
isolateGitConfig :: IO a -> IO a
isolateGitConfig a = Utility.Tmp.Dir.withTmpDir "testhome" $ \tmphome -> do
	tmphomeabs <- fromRawFilePath <$> absPath (toRawFilePath tmphome)
	Utility.Env.Set.setEnv "HOME" tmphomeabs True
	Utility.Env.Set.setEnv "XDG_CONFIG_HOME" tmphomeabs True
	Utility.Env.Set.setEnv "GIT_CONFIG_NOSYSTEM" "1" True
	a

removeDirectoryForCleanup :: FilePath -> IO ()
#if MIN_VERSION_directory(1,2,7)
removeDirectoryForCleanup = removePathForcibly
#else
removeDirectoryForCleanup = removeDirectoryRecursive
#endif

cleanup :: FilePath -> IO ()
cleanup dir = whenM (doesDirectoryExist dir) $ do
	Command.Uninit.prepareRemoveAnnexDir' dir
	-- This can fail if files in the directory are still open by a
	-- subprocess.
	void $ tryIO $ removeDirectoryForCleanup dir

finalCleanup :: IO ()
finalCleanup = whenM (doesDirectoryExist tmpdir) $ do
	Command.Uninit.prepareRemoveAnnexDir' tmpdir
	catchIO (removeDirectoryForCleanup tmpdir) $ \e -> do
		print e
		putStrLn "sleeping 10 seconds and will retry directory cleanup"
		Utility.ThreadScheduler.threadDelaySeconds $
			Utility.ThreadScheduler.Seconds 10
		whenM (doesDirectoryExist tmpdir) $
			removeDirectoryForCleanup tmpdir

checklink :: FilePath -> Assertion
checklink f = ifM (annexeval Config.crippledFileSystem)
	( (isJust <$> annexeval (Annex.Link.getAnnexLinkTarget (toRawFilePath f)))
		@? f ++ " is not a (crippled) symlink"
	, do
		s <- getSymbolicLinkStatus f
		isSymbolicLink s @? f ++ " is not a symlink"
	)

checkregularfile :: FilePath -> Assertion
checkregularfile f = do
	s <- getSymbolicLinkStatus f
	isRegularFile s @? f ++ " is not a normal file"
	return ()

checkdoesnotexist :: FilePath -> Assertion
checkdoesnotexist f = 
	(either (const True) (const False) <$> Utility.Exception.tryIO (getSymbolicLinkStatus f))
		@? f ++ " exists unexpectedly"

checkexists :: FilePath -> Assertion
checkexists f = 
	(either (const False) (const True) <$> Utility.Exception.tryIO (getSymbolicLinkStatus f))
		@? f ++ " does not exist"

checkcontent :: FilePath -> Assertion
checkcontent f = do
	c <- Utility.Exception.catchDefaultIO "could not read file" $ readFile f
	assertEqual ("checkcontent " ++ f) (content f) c

checkunwritable :: FilePath -> Assertion
checkunwritable f = do
	-- Look at permissions bits rather than trying to write or
	-- using fileAccess because if run as root, any file can be
	-- modified despite permissions.
	s <- getFileStatus f
	let mode = fileMode s
	when (mode == mode `unionFileModes` ownerWriteMode) $
		assertFailure $ "able to modify annexed file's " ++ f ++ " content"

checkwritable :: FilePath -> Assertion
checkwritable f = do
	s <- getFileStatus f
	let mode = fileMode s
	unless (mode == mode `unionFileModes` ownerWriteMode) $
		assertFailure $ "unable to modify " ++ f

checkdangling :: FilePath -> Assertion
checkdangling f = ifM (annexeval Config.crippledFileSystem)
	( return () -- probably no real symlinks to test
	, do
		r <- tryIO $ readFile f
		case r of
			Left _ -> return () -- expected; dangling link
			Right _ -> assertFailure $ f ++ " was not a dangling link as expected"
	)

checklocationlog :: FilePath -> Bool -> Assertion
checklocationlog f expected = do
	thisuuid <- annexeval Annex.UUID.getUUID
	r <- annexeval $ Annex.WorkTree.lookupKey (toRawFilePath f)
	case r of
		Just k -> do
			uuids <- annexeval $ Remote.keyLocations k
			assertEqual ("bad content in location log for " ++ f ++ " key " ++ Key.serializeKey k ++ " uuid " ++ show thisuuid)
				expected (thisuuid `elem` uuids)
		_ -> assertFailure $ f ++ " failed to look up key"

checkbackend :: FilePath -> Types.Backend -> Assertion
checkbackend file expected = do
	b <- annexeval $ maybe (return Nothing) (Backend.getBackend file) 
		=<< Annex.WorkTree.lookupKey (toRawFilePath file)
	assertEqual ("backend for " ++ file) (Just expected) b

checkispointerfile :: FilePath -> Assertion
checkispointerfile f = unlessM (isJust <$> Annex.Link.isPointerFile (toRawFilePath f)) $
	assertFailure $ f ++ " is not a pointer file"

inlocationlog :: FilePath -> Assertion
inlocationlog f = checklocationlog f True

notinlocationlog :: FilePath -> Assertion
notinlocationlog f = checklocationlog f False

runchecks :: [FilePath -> Assertion] -> FilePath -> Assertion
runchecks [] _ = return ()
runchecks (a:as) f = do
	a f
	runchecks as f

annexed_notpresent :: FilePath -> Assertion
annexed_notpresent f = ifM (hasUnlockedFiles <$> getTestMode)
	( annexed_notpresent_unlocked f
	, annexed_notpresent_locked f
	)

annexed_notpresent_locked :: FilePath -> Assertion
annexed_notpresent_locked = runchecks [checklink, checkdangling, notinlocationlog]

annexed_notpresent_unlocked :: FilePath -> Assertion
annexed_notpresent_unlocked = runchecks [checkregularfile, checkispointerfile, notinlocationlog]

annexed_present :: FilePath -> Assertion
annexed_present f = ifM (hasUnlockedFiles <$> getTestMode)
	( annexed_present_unlocked f
	, annexed_present_locked f
	)

annexed_present_locked :: FilePath -> Assertion
annexed_present_locked f = ifM (annexeval Config.crippledFileSystem)
	( runchecks [checklink, inlocationlog] f
	, runchecks [checklink, checkcontent, checkunwritable, inlocationlog] f
	)

annexed_present_unlocked :: FilePath -> Assertion
annexed_present_unlocked = runchecks
	[checkregularfile, checkcontent, checkwritable, inlocationlog]
	
annexed_present_imported :: FilePath -> Assertion
annexed_present_imported f = ifM (annexeval Config.crippledFileSystem)
	( annexed_present_unlocked f
	, ifM (adjustedUnlockedBranch <$> getTestMode) 
		( annexed_present_unlocked f
		, annexed_present_locked f
		)
	)

annexed_notpresent_imported :: FilePath -> Assertion
annexed_notpresent_imported f = ifM (annexeval Config.crippledFileSystem)
	( annexed_notpresent_unlocked f
	, ifM (adjustedUnlockedBranch <$> getTestMode)
		( annexed_notpresent_unlocked f
		, annexed_notpresent_locked f
		)
	)

unannexed :: FilePath -> Assertion
unannexed = runchecks [checkregularfile, checkcontent, checkwritable]

-- Check that a file is unannexed, but also that what's recorded in git
-- is not an annexed file.
unannexed_in_git :: FilePath -> Assertion
unannexed_in_git f = do
	unannexed f
	r <- annexeval $ Annex.WorkTree.lookupKey (toRawFilePath f)
	case r of
		Just _k -> assertFailure $ f ++ " is annexed in git"
		Nothing -> return ()

add_annex :: FilePath -> String -> Assertion
add_annex f faildesc = ifM (unlockedFiles <$> getTestMode)
	( git "add" [f] faildesc
	, git_annex "add" [f] faildesc
	)

data TestMode = TestMode
	{ unlockedFiles :: Bool
	, adjustedUnlockedBranch :: Bool
	, annexVersion :: Types.RepoVersion.RepoVersion
	, keepFailures :: Bool
	} deriving (Read, Show)

testMode :: TestOptions -> Types.RepoVersion.RepoVersion -> TestMode
testMode opts v = TestMode
	{ unlockedFiles = False
	, adjustedUnlockedBranch = False
	, annexVersion = v
	, keepFailures = keepFailuresOption opts
	}

hasUnlockedFiles :: TestMode -> Bool
hasUnlockedFiles m = unlockedFiles m || adjustedUnlockedBranch m

withTestMode :: TestMode -> TestTree -> TestTree
withTestMode testmode = withResource prepare release . const
  where
	prepare = do
		setTestMode testmode
		setmainrepodir =<< newmainrepodir
	release _ = noop

setTestMode :: TestMode -> IO ()
setTestMode testmode = do
	currdir <- getCurrentDirectory
	p <- Utility.Env.getEnvDefault "PATH" ""
	pp <- Annex.Path.programPath

	mapM_ (\(var, val) -> Utility.Env.Set.setEnv var val True)
		-- Ensure that the same git-annex binary that is running
		-- git-annex test is at the front of the PATH.
		[ ("PATH", takeDirectory pp ++ [searchPathSeparator] ++ p)
		, ("TOPDIR", currdir)
		-- Avoid git complaining if it cannot determine the user's
		-- email address, or exploding if it doesn't know the user's
		-- name.
		, ("GIT_AUTHOR_EMAIL", "test@example.com")
		, ("GIT_AUTHOR_NAME", "git-annex test")
		, ("GIT_COMMITTER_EMAIL", "test@example.com")
		, ("GIT_COMMITTER_NAME", "git-annex test")
		-- force gpg into batch mode for the tests
		, ("GPG_BATCH", "1")
		-- Make git and git-annex access ssh remotes on the local
		-- filesystem, without using ssh at all.
		, ("GIT_SSH_COMMAND", "git-annex test --fakessh --")
		, ("GIT_ANNEX_USE_GIT_SSH", "1")
		, ("TESTMODE", show testmode)
		]
				
runFakeSsh :: [String] -> IO ()
runFakeSsh ("-n":ps) = runFakeSsh ps
runFakeSsh (_host:cmd:[]) =
	withCreateProcess (shell cmd) $
		\_ _ _ pid -> exitWith =<< waitForProcess pid
runFakeSsh ps = error $ "fake ssh option parse error: " ++ show ps

getTestMode :: IO TestMode
getTestMode = Prelude.read <$> Utility.Env.getEnvDefault "TESTMODE" ""

setupTestMode :: IO ()
setupTestMode = do
	testmode <- getTestMode
	when (adjustedUnlockedBranch testmode) $ do
		git "commit" ["--allow-empty", "-m", "empty"] "git commit failed"
		git_annex "adjust" ["--unlock"] "git annex adjust failed"

changeToTopDir :: FilePath -> IO ()
changeToTopDir t = do
	topdir <- Utility.Env.getEnvDefault "TOPDIR" (error "TOPDIR not set")
	setCurrentDirectory $ topdir ++ "/" ++ t

tmpdir :: String
tmpdir = ".t"

mainrepodir :: IO FilePath
mainrepodir = Utility.Env.getEnvDefault "MAINREPODIR"
	(giveup "MAINREPODIR not set")

setmainrepodir :: FilePath -> IO ()
setmainrepodir d = Utility.Env.Set.setEnv "MAINREPODIR" d True

newmainrepodir :: IO FilePath
newmainrepodir = go (0 :: Int)
  where
	go n = do
		let d = "main" ++ show n
		ifM (doesDirectoryExist d)
			( go $ n + 1
			, do
				createDirectory d
				return d
			)

tmprepodir :: IO FilePath
tmprepodir = go (0 :: Int)
  where
	go n = do
		let d = "tmprepo" ++ show n
		ifM (doesDirectoryExist d)
			( go $ n + 1
			, return d
			)

annexedfile :: String
annexedfile = "foo"

annexedfiledup :: String
annexedfiledup = "foodup"

wormannexedfile :: String
wormannexedfile = "apple"

sha1annexedfile :: String
sha1annexedfile = "sha1foo"

sha1annexedfiledup :: String
sha1annexedfiledup = "sha1foodup"

ingitfile :: String
ingitfile = "bar.c"

content :: FilePath -> String		
content f
	| f == annexedfile = "annexed file content"
	| f == ingitfile = "normal file content"
	| f == sha1annexedfile ="sha1 annexed file content"
	| f == annexedfiledup = content annexedfile
	| f == sha1annexedfiledup = content sha1annexedfile
	| f == wormannexedfile = "worm annexed file content"
	| "import" `isPrefixOf` f = "imported content"
	| otherwise = "unknown file " ++ f

-- Writes new content to a file, and makes sure that it has a different
-- mtime than it did before
writecontent :: FilePath -> String -> IO ()
writecontent f c = go (10000000 :: Integer)
  where
	go ticsleft = do
		oldmtime <- catchMaybeIO $ getModificationTime f
		writeFile f c
		newmtime <- getModificationTime f
		if Just newmtime == oldmtime
			then do
				threadDelay 100000
				let ticsleft' = ticsleft - 100000
				if ticsleft' > 0
					then go ticsleft'
					else do
						hPutStrLn stderr "file mtimes do not seem to be changing (tried for 10 seconds)"
						hFlush stderr
						return ()
			else return ()

changecontent :: FilePath -> IO ()
changecontent f = writecontent f $ changedcontent f

changedcontent :: FilePath -> String
changedcontent f = content f ++ " (modified)"

backendSHA1 :: Types.Backend
backendSHA1 = backend_ "SHA1"

backendSHA256 :: Types.Backend
backendSHA256 = backend_ "SHA256"

backendSHA256E :: Types.Backend
backendSHA256E = backend_ "SHA256E"

backendWORM :: Types.Backend
backendWORM = backend_ "WORM"

backend_ :: String -> Types.Backend
backend_ = Backend.lookupBuiltinBackendVariety . Types.Key.parseKeyVariety . encodeBS

getKey :: Types.Backend -> FilePath -> IO Types.Key
getKey b f = case Types.Backend.genKey b of
	Just a -> annexeval $ a ks Utility.Metered.nullMeterUpdate
	Nothing -> error "internal"
  where
	ks = Types.KeySource.KeySource
		{ Types.KeySource.keyFilename = toRawFilePath f
		, Types.KeySource.contentLocation = toRawFilePath f
		, Types.KeySource.inodeCache = Nothing
		}

{- Get the name of the original branch, eg the current branch, or
 - if in an adjusted branch, the parent branch. -}
origBranch :: Types.Annex String
origBranch = maybe "foo"
	(Git.Types.fromRef . Git.Ref.base . Annex.AdjustedBranch.fromAdjustedBranch)
	<$> Annex.inRepo Git.Branch.current

{- Set up repos as remotes of each other. -}
pair :: FilePath -> FilePath -> Assertion
pair r1 r2 = forM_ [r1, r2] $ \r -> indir r $ do
	when (r /= r1) $
		git "remote" ["add", "r1", "../" ++ r1] "remote add"
	when (r /= r2) $
		git "remote" ["add", "r2", "../" ++ r2] "remote add"


{- Runs a query in the current repository, but first makes the repository
 - read-only. The write bit is added back at the end, so when possible, 
 - include multiple tests within a single call for efficiency. -}
readonly_query :: Assertion -> Assertion
readonly_query = bracket_ (make_readonly ".") (make_writeable ".")
	
{- Not guaranteed to do anything: 
 - chmod may fail, or not be available, or the filesystem not support
 - permissions. -}
make_readonly :: FilePath -> IO ()
make_readonly d = void $
	Utility.Process.Transcript.processTranscript
		"chmod" ["-R", "-w", d] Nothing

{- The write bit is added back for the current user, but not for other
 - users, even though make_readonly removes any other user's write bits. -}
make_writeable :: FilePath -> IO ()
make_writeable d = void $
	Utility.Process.Transcript.processTranscript
		"chmod" ["-R", "u+w", d] Nothing

{- Tests each TestTree in parallel, and exits with succcess/failure.
 -
 - Tasty supports parallel tests, but this does not use it, because
 - many tests need to be run in test repos, and chdir would not be 
 - thread safe. Instead, this starts one child process for each TestTree.
 -
 - An added benefit of using child processes is that any files they may
 - leave open are closed before finalCleanup is run at the end. This
 - prevents some failures to clean up after the test suite.
 -}
parallelTestRunner :: TestOptions -> (Int -> Bool -> Bool -> TestOptions -> [TestTree]) -> IO ()
parallelTestRunner opts mkts = do
	numjobs <- case concurrentJobs opts of
		Just NonConcurrent -> pure 1
		Just (Concurrent n) -> pure n
		Just ConcurrentPerCpu -> getNumProcessors
		Nothing -> getNumProcessors
	parallelTestRunner' numjobs opts mkts

parallelTestRunner' :: Int -> TestOptions -> (Int -> Bool -> Bool -> TestOptions -> [TestTree]) -> IO ()
parallelTestRunner' numjobs opts mkts
	| fakeSsh opts = runFakeSsh (internalData opts)
	| otherwise = go =<< Utility.Env.getEnv subenv
  where
	subenv = "GIT_ANNEX_TEST_SUBPROCESS"
	-- Make more parts than there are jobs, because some parts
	-- are larger, and this allows the smaller parts to be packed
	-- in more efficiently, speeding up the test suite overall.
	numparts = numjobs * 2
	worker rs nvar a = do
		(n, m) <- atomically $ do
			(n, m) <- readTVar nvar
			writeTVar nvar (n+1, m)
			return (n, m)
		if n > m
			then return rs
			else do
				r <- a n
				worker (r:rs) nvar a
	go Nothing = withConcurrentOutput $ do
		ensuredir tmpdir
		crippledfilesystem <- fst <$> Annex.Init.probeCrippledFileSystem'
			(toRawFilePath tmpdir)
			Nothing Nothing False
		adjustedbranchok <- Annex.AdjustedBranch.isGitVersionSupported
		let ts = mkts numparts crippledfilesystem adjustedbranchok opts
		let warnings = fst (tastyParser ts)
		unless (null warnings) $ do
			hPutStrLn stderr "warnings from tasty:"
			mapM_ (hPutStrLn stderr) warnings
		environ <- Utility.Env.getEnvironment
		args <- getArgs
		pp <- Annex.Path.programPath
		termcolor <- hSupportsANSIColor stdout
		let ps = if useColor (lookupOption (tastyOptionSet opts)) termcolor
			then "--color=always":args
			else "--color=never":args
		let runone n = do
			let subdir = tmpdir </> show n
			ensuredir subdir
			let p = (proc pp ps)
				{ env = Just ((subenv, show (n, crippledfilesystem, adjustedbranchok)):environ)
				, cwd = Just subdir
				}
			(_, _, _, pid) <- createProcessConcurrent p
			ret <- waitForProcess pid
			-- Work around this strange issue
			-- https://github.com/UnkindPartition/tasty/issues/326
			-- when other workaround does not work.
			if ret == ExitFailure (-11)
				then runone n
				else return ret
		nvar <- newTVarIO (1, length ts)
		exitcodes <- forConcurrently [1..numjobs] $ \_ -> 
			worker [] nvar runone
		unless (keepFailuresOption opts) finalCleanup
		case nub (filter (/= ExitSuccess) (concat exitcodes)) of
			[] -> exitSuccess
			[ExitFailure 1] -> do
				putStrLn "  (Failures above could be due to a bug in git-annex, or an incompatibility"
				putStrLn "   with utilities, such as git, installed on this system.)"
				exitFailure
			_ -> do
				putStrLn $ "  Test subprocesses exited with unexpected exit codes: " ++ show (concat exitcodes)
				exitFailure
	go (Just subenvval) = case readish subenvval of
		Nothing -> error ("Bad " ++ subenv)
		Just (n, crippledfilesystem, adjustedbranchok) -> isolateGitConfig $ do
			let ts = mkts numparts crippledfilesystem adjustedbranchok opts
			let t = topLevelTestGroup 
				-- Work around this strange issue
				-- https://github.com/UnkindPartition/tasty/issues/326
				[ testGroup "Tasty" 
					[ testProperty "tasty self-check" True
					]
				, ts !! (n - 1)
				]
			case tryIngredients ingredients (tastyOptionSet opts) t of
				Nothing -> error "No tests found!?"
				Just act -> ifM act
					( exitSuccess
					, exitFailure
							)

topLevelTestGroup :: [TestTree] -> TestTree
topLevelTestGroup = testGroup "Tests"

tastyParser :: [TestTree] -> ([String], Parser Test.Tasty.Options.OptionSet)
#if MIN_VERSION_tasty(1,3,0)
tastyParser ts = go
#else
tastyParser ts = ([], go)
#endif
  where
 	go = suiteOptionParser ingredients (topLevelTestGroup ts)

ingredients :: [Ingredient]
ingredients =
	[ listingTests
	, rerunningTests [consoleTestReporter]
	]

