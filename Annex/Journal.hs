{- management of the git-annex journal
 -
 - The journal is used to queue up changes before they are committed to the
 - git-annex branch. Among other things, it ensures that if git-annex is
 - interrupted, its recorded data is not lost.
 -
 - Copyright 2011-2021 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE OverloadedStrings #-}

module Annex.Journal where

import Annex.Common
import qualified Annex
import qualified Git
import Annex.Perms
import Annex.Tmp
import Annex.LockFile
import Utility.Directory.Stream

import qualified Data.Set as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString as B
import qualified System.FilePath.ByteString as P
import Data.ByteString.Builder
import Data.Char

class Journalable t where
	writeJournalHandle :: Handle -> t -> IO ()
	journalableByteString :: t -> L.ByteString

instance Journalable L.ByteString where
	writeJournalHandle = L.hPut
	journalableByteString = id

-- This is more efficient than the ByteString instance.
instance Journalable Builder where
	writeJournalHandle = hPutBuilder
	journalableByteString = toLazyByteString

{- When a file in the git-annex branch is changed, this indicates what
 - repository UUID (or in some cases, UUIDs) a change is regarding.
 -
 - Using this lets changes regarding private UUIDs be stored separately
 - from the git-annex branch, so its information does not get exposed
 - outside the repo.
 -}
data RegardingUUID = RegardingUUID [UUID]

regardingPrivateUUID :: RegardingUUID -> Annex Bool
regardingPrivateUUID (RegardingUUID []) = pure False
regardingPrivateUUID (RegardingUUID us) = do
	s <- annexPrivateRepos <$> Annex.getGitConfig
	return (any (flip S.member s) us)

{- Are any private UUIDs known to exist? If so, extra work has to be done,
 - to check for information separately recorded for them, outside the usual
 - locations.
 -}
privateUUIDsKnown :: Annex Bool
privateUUIDsKnown = privateUUIDsKnown' <$> Annex.getState id

privateUUIDsKnown' :: Annex.AnnexState -> Bool
privateUUIDsKnown' = not . S.null . annexPrivateRepos . Annex.gitconfig

{- Records content for a file in the branch to the journal.
 -
 - Using the journal, rather than immediatly staging content to the index
 - avoids git needing to rewrite the index after every change.
 - 
 - The file in the journal is updated atomically, which allows
 - getJournalFileStale to always return a consistent journal file
 - content, although possibly not the most current one.
 -}
setJournalFile :: Journalable content => JournalLocked -> RegardingUUID -> RawFilePath -> content -> Annex ()
setJournalFile _jl ru file content = withOtherTmp $ \tmp -> do
	jd <- fromRepo =<< ifM (regardingPrivateUUID ru)
		( return gitAnnexPrivateJournalDir
		, return gitAnnexJournalDir
		)
	createAnnexDirectory jd
	-- journal file is written atomically
	let jfile = journalFile file
	let tmpfile = fromRawFilePath (tmp P.</> jfile)
	liftIO $ do
		withFile tmpfile WriteMode $ \h -> writeJournalHandle h content
		moveFile tmpfile (fromRawFilePath (jd P.</> jfile))

data JournalledContent
	= NoJournalledContent
	| JournalledContent L.ByteString
	| PossiblyStaleJournalledContent L.ByteString
	-- ^ This is used when the journalled content may have been 
	-- supersceded by content in the git-annex branch. The returned
	-- content should be combined with content from the git-annex branch.
	-- This is particularly the case when a file is in the private
	-- journal, which does not get written to the git-annex branch,
	-- and so the git-annex branch can contain changes to non-private
	-- information that were made after that journal file was written.

{- Gets any journalled content for a file in the branch. -}
getJournalFile :: JournalLocked -> GetPrivate -> RawFilePath -> Annex JournalledContent
getJournalFile _jl = getJournalFileStale

data GetPrivate = GetPrivate Bool

{- Without locking, this is not guaranteed to be the most recent
 - version of the file in the journal, so should not be used as a basis for
 - changes.
 -
 - The file is read strictly so that its content can safely be fed into
 - an operation that modifies the file. While setJournalFile doesn't
 - write directly to journal files and so probably avoids problems with
 - writing to the same file that's being read, but there could be
 - concurrency or other issues with a lazy read, and the minor loss of
 - laziness doesn't matter much, as the files are not very large.
 -}
getJournalFileStale :: GetPrivate -> RawFilePath -> Annex JournalledContent
getJournalFileStale (GetPrivate getprivate) file = do
	-- Optimisation to avoid a second MVar access.
	st <- Annex.getState id
	let g = Annex.repo st
	liftIO $
		if getprivate && privateUUIDsKnown' st
		then do
			x <- getfrom (gitAnnexJournalDir g)
			getfrom (gitAnnexPrivateJournalDir g) >>= \case
				Nothing -> return $ case x of
					Nothing -> NoJournalledContent
					Just b -> JournalledContent b
				Just y -> return $ PossiblyStaleJournalledContent $ case x of
					Nothing -> y
					-- This concacenation is the same as
					-- happens in a merge of two
					-- git-annex branches.
					Just x' -> x' <> y
		else getfrom (gitAnnexJournalDir g) >>= return . \case
			Nothing -> NoJournalledContent
			Just b -> JournalledContent b
  where
	jfile = journalFile file
	getfrom d = catchMaybeIO $
		L.fromStrict <$> B.readFile (fromRawFilePath (d P.</> jfile))

{- List of existing journal files in a journal directory, but without locking,
 - may miss new ones just being added, or may have false positives if the
 - journal is staged as it is run. -}
getJournalledFilesStale :: (Git.Repo -> RawFilePath) -> Annex [RawFilePath]
getJournalledFilesStale getjournaldir = do
	g <- gitRepo
	fs <- liftIO $ catchDefaultIO [] $
		getDirectoryContents $ fromRawFilePath (getjournaldir g)
	return $ filter (`notElem` [".", ".."]) $
		map (fileJournal . toRawFilePath) fs

{- Directory handle open on a journal directory. -}
withJournalHandle :: (Git.Repo -> RawFilePath) -> (DirectoryHandle -> IO a) -> Annex a
withJournalHandle getjournaldir a = do
	d <- fromRawFilePath <$> fromRepo getjournaldir
	bracketIO (openDirectory d) closeDirectory (liftIO . a)

{- Checks if there are changes in the journal. -}
journalDirty :: (Git.Repo -> RawFilePath) -> Annex Bool
journalDirty getjournaldir = do
	d <- fromRawFilePath <$> fromRepo getjournaldir
	liftIO $ 
		(not <$> isDirectoryEmpty d)
			`catchIO` (const $ doesDirectoryExist d)

{- Produces a filename to use in the journal for a file on the branch.
 - The filename does not include the journal directory.
 -
 - The journal typically won't have a lot of files in it, so the hashing
 - used in the branch is not necessary, and all the files are put directly
 - in the journal directory.
 -}
journalFile :: RawFilePath -> RawFilePath
journalFile file = B.concatMap mangle file
  where
	mangle c
		| P.isPathSeparator c = B.singleton underscore
		| c == underscore = B.pack [underscore, underscore]
		| otherwise = B.singleton c
	underscore = fromIntegral (ord '_')

{- Converts a journal file (relative to the journal dir) back to the
 - filename on the branch. -}
fileJournal :: RawFilePath -> RawFilePath
fileJournal = go
  where
	go b = 
		let (h, t) = B.break (== underscore) b
		in h <> case B.uncons t of
			Nothing -> t
			Just (_u, t') -> case B.uncons t' of
				Nothing -> t'			
				Just (w, t'')
					| w == underscore ->
						B.cons underscore (go t'')
					| otherwise -> 
						B.cons P.pathSeparator (go t')
	
	underscore = fromIntegral (ord '_')

{- Sentinal value, only produced by lockJournal; required
 - as a parameter by things that need to ensure the journal is
 - locked. -}
data JournalLocked = ProduceJournalLocked

{- Runs an action that modifies the journal, using locking to avoid
 - contention with other git-annex processes. -}
lockJournal :: (JournalLocked -> Annex a) -> Annex a
lockJournal a = withExclusiveLock gitAnnexJournalLock $ a ProduceJournalLocked
