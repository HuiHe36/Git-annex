{- git-annex command-line option parsing
 -
 - Copyright 2010-2021 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}

module CmdLine.GitAnnex.Options where

import Control.Monad.Fail as Fail (MonadFail(..))
import Options.Applicative
import Data.Time.Clock.POSIX
import Control.Concurrent.STM
import qualified Data.Map as M

import Annex.Common
import qualified Git.Config
import qualified Git.Construct
import Git.Remote
import Git.Types
import Types.Key
import Types.TrustLevel
import Types.NumCopies
import Types.Messages
import Types.Command
import Types.DeferredParse
import Types.DesktopNotify
import Types.Concurrency
import qualified Annex
import qualified Remote
import qualified Limit
import qualified Limit.Wanted
import CmdLine.Option
import CmdLine.Usage
import CmdLine.GlobalSetter
import qualified Backend
import qualified Types.Backend as Backend
import Utility.HumanTime
import Utility.DataUnits
import Annex.Concurrent

-- Global options that are accepted by all git-annex sub-commands,
-- although not always used.
gitAnnexGlobalOptions :: [GlobalOption]
gitAnnexGlobalOptions = commonGlobalOptions ++
	[ globalOption (setAnnexState . setnumcopies) $ option auto
		( long "numcopies" <> short 'N' <> metavar paramNumber
		<> help "override desired number of copies"
		<> hidden
		)
	, globalOption (setAnnexState . setmincopies) $ option auto
		( long "mincopies" <> short 'N' <> metavar paramNumber
		<> help "override minimum number of copies"
		<> hidden
		)
	, globalOption (setAnnexState . Remote.forceTrust Trusted) $ strOption
		( long "trust" <> metavar paramRemote
		<> help "deprecated, does not override trust setting"
		<> hidden
		<> completeRemotes
		)
	, globalOption (setAnnexState . Remote.forceTrust SemiTrusted) $ strOption
		( long "semitrust" <> metavar paramRemote
		<> help "override trust setting back to default"
		<> hidden
		<> completeRemotes
		)
	, globalOption (setAnnexState . Remote.forceTrust UnTrusted) $ strOption
		( long "untrust" <> metavar paramRemote
		<> help "override trust setting to untrusted"
		<> hidden
		<> completeRemotes
		)
	, globalOption (setAnnexState . setgitconfig) $ strOption
		( long "config" <> short 'c' <> metavar "NAME=VALUE"
		<> help "override git configuration setting"
		<> hidden
		)
	, globalOption (setAnnexState . setuseragent) $ strOption
		( long "user-agent" <> metavar paramName
		<> help "override default User-Agent"
		<> hidden
		)
	, globalFlag (setAnnexState $ toplevelWarning False "--trust-glacier no longer has any effect")
		( long "trust-glacier"
		<> help "deprecated, does not trust Amazon Glacier inventory"
		<> hidden
		)
	, globalFlag (setAnnexState $ setdesktopnotify mkNotifyFinish)
		( long "notify-finish"
		<> help "show desktop notification after transfer finishes"
		<> hidden
		)
	, globalFlag (setAnnexState $ setdesktopnotify mkNotifyStart)
		( long "notify-start"
		<> help "show desktop notification after transfer starts"
		<> hidden
		)
	]
  where
	setnumcopies n = Annex.changeState $ \s -> s { Annex.forcenumcopies = Just $ configuredNumCopies n }
	setmincopies n = Annex.changeState $ \s -> s { Annex.forcemincopies = Just $ configuredMinCopies n }
	setuseragent v = Annex.changeState $ \s -> s { Annex.useragent = Just v }
	setgitconfig v = Annex.addGitConfigOverride v
	setdesktopnotify v = Annex.changeState $ \s -> s { Annex.desktopnotify = Annex.desktopnotify s <> v }

{- Parser that accepts all non-option params. -}
cmdParams :: CmdParamsDesc -> Parser CmdParams
cmdParams paramdesc = many $ argument str
	( metavar paramdesc
	<> action "file"
	)

parseAutoOption :: Parser Bool
parseAutoOption = switch
	( long "auto" <> short 'a'
	<> help "automatic mode"
	)

parseRemoteOption :: RemoteName -> DeferredParse Remote
parseRemoteOption = DeferredParse 
	. (fromJust <$$> Remote.byNameWithUUID)
	. Just

parseUUIDOption :: String -> DeferredParse UUID
parseUUIDOption = DeferredParse
	. (Remote.nameToUUID)

-- | From or To a remote.
data FromToOptions
	= FromRemote (DeferredParse Remote)
	| ToRemote (DeferredParse Remote)

instance DeferredParseClass FromToOptions where
	finishParse (FromRemote v) = FromRemote <$> finishParse v
	finishParse (ToRemote v) = ToRemote <$> finishParse v

parseFromToOptions :: Parser FromToOptions
parseFromToOptions = 
	(FromRemote . parseRemoteOption <$> parseFromOption) 
	<|> (ToRemote . parseRemoteOption <$> parseToOption)

parseFromOption :: Parser RemoteName
parseFromOption = strOption
	( long "from" <> short 'f' <> metavar paramRemote
	<> help "source remote"
	<> completeRemotes
	)

parseToOption :: Parser RemoteName
parseToOption = strOption
	( long "to" <> short 't' <> metavar paramRemote
	<> help "destination remote"
	<> completeRemotes
	)

-- | Like FromToOptions, but with a special --to=here
type FromToHereOptions = Either ToHere FromToOptions

data ToHere = ToHere

parseFromToHereOptions :: Parser FromToHereOptions
parseFromToHereOptions = parsefrom <|> parseto
  where
	parsefrom = Right . FromRemote . parseRemoteOption <$> parseFromOption
	parseto = herespecialcase <$> parseToOption
	  where
		herespecialcase "here" = Left ToHere
		herespecialcase "." = Left ToHere
		herespecialcase n = Right $ ToRemote $ parseRemoteOption n

instance DeferredParseClass FromToHereOptions where
	finishParse = either (pure . Left) (Right <$$> finishParse)

-- Options for acting on keys, rather than work tree files.
data KeyOptions
	= WantAllKeys
	| WantUnusedKeys
	| WantFailedTransfers
	| WantSpecificKey Key
	| WantIncompleteKeys
	| WantBranchKeys [Branch]

parseKeyOptions :: Parser KeyOptions
parseKeyOptions = parseAllOption
	<|> parseBranchKeysOption
	<|> parseUnusedKeysOption
	<|> parseSpecificKeyOption

parseUnusedKeysOption :: Parser KeyOptions
parseUnusedKeysOption = flag' WantUnusedKeys
	( long "unused" <> short 'U'
	<> help "operate on files found by last run of git-annex unused"
	)

parseSpecificKeyOption :: Parser KeyOptions
parseSpecificKeyOption = WantSpecificKey <$> option (str >>= parseKey)
	( long "key" <> metavar paramKey
	<> help "operate on specified key"
	)

parseBranchKeysOption :: Parser KeyOptions
parseBranchKeysOption = WantBranchKeys <$> some (option (str >>= pure . Ref)
	( long "branch" <> metavar paramRef
	<> help "operate on files in the specified branch or treeish"
	))

parseFailedTransfersOption :: Parser KeyOptions
parseFailedTransfersOption = flag' WantFailedTransfers
	( long "failed"
	<> help "operate on files that recently failed to be transferred"
	)

parseIncompleteOption :: Parser KeyOptions
parseIncompleteOption = flag' WantIncompleteKeys
	( long "incomplete"
	<> help "resume previous downloads"
	)

parseAllOption :: Parser KeyOptions
parseAllOption = flag' WantAllKeys
	( long "all" <> short 'A'
	<> help "operate on all versions of all files"
	)

parseKey :: MonadFail m => String -> m Key
parseKey = maybe (Fail.fail "invalid key") return . deserializeKey

-- Options to match properties of annexed files.
annexedMatchingOptions :: [GlobalOption]
annexedMatchingOptions = concat
	[ keyMatchingOptions'
	, fileMatchingOptions' Limit.LimitAnnexFiles
	, combiningOptions
	, timeLimitOption
	, sizeLimitOption
	]

-- Matching options that can operate on keys as well as files.
keyMatchingOptions :: [GlobalOption]
keyMatchingOptions = keyMatchingOptions' ++ combiningOptions ++ timeLimitOption ++ sizeLimitOption

keyMatchingOptions' :: [GlobalOption]
keyMatchingOptions' = 
	[ globalOption (setAnnexState . Limit.addIn) $ strOption
		( long "in" <> short 'i' <> metavar paramRemote
		<> help "match files present in a remote"
		<> hidden
		<> completeRemotes
		)
	, globalOption (setAnnexState . Limit.addCopies) $ strOption
		( long "copies" <> short 'C' <> metavar paramRemote
		<> help "skip files with fewer copies"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addLackingCopies False) $ strOption
		( long "lackingcopies" <> metavar paramNumber
		<> help "match files that need more copies"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addLackingCopies True) $ strOption
		( long "approxlackingcopies" <> metavar paramNumber
		<> help "match files that need more copies (faster)"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addInBackend) $ strOption
		( long "inbackend" <> short 'B' <> metavar paramName
		<> help "match files using a key-value backend"
		<> hidden
		<> completeBackends
		)
	, globalFlag (setAnnexState Limit.addSecureHash)
		( long "securehash"
		<> help "match files using a cryptographically secure hash"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addInAllGroup) $ strOption
		( long "inallgroup" <> metavar paramGroup
		<> help "match files present in all remotes in a group"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addMetaData) $ strOption
		( long "metadata" <> metavar "FIELD=VALUE"
		<> help "match files with attached metadata"
		<> hidden
		)
	, globalFlag (setAnnexState Limit.Wanted.addWantGet)
		( long "want-get"
		<> help "match files the repository wants to get"
		<> hidden
		)
	, globalFlag (setAnnexState Limit.Wanted.addWantDrop)
		( long "want-drop"
		<> help "match files the repository wants to drop"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addAccessedWithin) $
		option (eitherReader parseDuration)
			( long "accessedwithin"
			<> metavar paramTime
			<> help "match files accessed within a time interval"
			<> hidden
			)
	, globalOption (setAnnexState . Limit.addMimeType) $ strOption
		( long "mimetype" <> metavar paramGlob
		<> help "match files by mime type"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addMimeEncoding) $ strOption
		( long "mimeencoding" <> metavar paramGlob
		<> help "match files by mime encoding"
		<> hidden
		)
	, globalFlag (setAnnexState Limit.addUnlocked)
		( long "unlocked"
		<> help "match files that are unlocked"
		<> hidden
		)
	, globalFlag (setAnnexState Limit.addLocked)
		( long "locked"
		<> help "match files that are locked"
		<> hidden
		)
	]

-- Options to match files which may not yet be annexed.
fileMatchingOptions :: Limit.LimitBy -> [GlobalOption]
fileMatchingOptions lb = fileMatchingOptions' lb ++ combiningOptions ++ timeLimitOption

fileMatchingOptions' :: Limit.LimitBy -> [GlobalOption]
fileMatchingOptions' lb =
	[ globalOption (setAnnexState . Limit.addExclude) $ strOption
		( long "exclude" <> short 'x' <> metavar paramGlob
		<> help "skip files matching the glob pattern"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addInclude) $ strOption
		( long "include" <> short 'I' <> metavar paramGlob
		<> help "limit to files matching the glob pattern"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addExcludeSameContent) $ strOption
		( long "excludesamecontent" <> short 'x' <> metavar paramGlob
		<> help "skip files whose content is the same as another file matching the glob pattern"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addIncludeSameContent) $ strOption
		( long "includesamecontent" <> short 'I' <> metavar paramGlob
		<> help "limit to files whose content is the same as another file matching the glob pattern"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addLargerThan lb) $ strOption
		( long "largerthan" <> metavar paramSize
		<> help "match files larger than a size"
		<> hidden
		)
	, globalOption (setAnnexState . Limit.addSmallerThan lb) $ strOption
		( long "smallerthan" <> metavar paramSize
		<> help "match files smaller than a size"
		<> hidden
		)
	]

combiningOptions :: [GlobalOption]
combiningOptions = 
	[ longopt "not" "negate next option"
	, longopt "and" "both previous and next option must match"
	, longopt "or" "either previous or next option must match"
	, shortopt '(' "open group of options"
	, shortopt ')' "close group of options"
	]
  where
	longopt o h = globalFlag (setAnnexState $ Limit.addSyntaxToken o)
		( long o <> help h <> hidden )
	shortopt o h = globalFlag (setAnnexState $ Limit.addSyntaxToken [o])
		( short o <> help h <> hidden )

jsonOptions :: [GlobalOption]
jsonOptions = 
	[ globalFlag (setAnnexState $ Annex.setOutput (JSONOutput stdjsonoptions))
		( long "json" <> short 'j'
		<> help "enable JSON output"
		<> hidden
		)
	, globalFlag (setAnnexState $ Annex.setOutput (JSONOutput jsonerrormessagesoptions))
		( long "json-error-messages"
		<> help "include error messages in JSON"
		<> hidden
		)
	]
  where
	stdjsonoptions = JSONOptions
		{ jsonProgress = False
		, jsonErrorMessages = False
		}
	jsonerrormessagesoptions = stdjsonoptions { jsonErrorMessages = True }

jsonProgressOption :: [GlobalOption]
jsonProgressOption = 
	[ globalFlag (setAnnexState $ Annex.setOutput (JSONOutput jsonoptions))
		( long "json-progress"
		<> help "include progress in JSON output"
		<> hidden
		)
	]
  where
	jsonoptions = JSONOptions
		{ jsonProgress = True
		, jsonErrorMessages = False
		}

-- Note that a command that adds this option should wrap its seek
-- action in `allowConcurrentOutput`.
jobsOption :: [GlobalOption]
jobsOption = 
	[ globalOption (setAnnexState . setConcurrency . ConcurrencyCmdLine) $ 
		option (maybeReader parseConcurrency)
			( long "jobs" <> short 'J' 
			<> metavar (paramNumber `paramOr` "cpus")
			<> help "enable concurrent jobs"
			<> hidden
			)
	]

timeLimitOption :: [GlobalOption]
timeLimitOption = 
	[ globalOption settimelimit $ option (eitherReader parseDuration)
		( long "time-limit" <> short 'T' <> metavar paramTime
		<> help "stop after the specified amount of time"
		<> hidden
		)
	]
  where
	settimelimit duration = setAnnexState $ do
		start <- liftIO getPOSIXTime
		let cutoff = start + durationToPOSIXTime duration
		Annex.changeState $ \s -> s { Annex.timelimit = Just (duration, cutoff) }

sizeLimitOption :: [GlobalOption]
sizeLimitOption =
	[ globalOption setsizelimit $ option (maybeReader (readSize dataUnits))
		( long "size-limit" <> metavar paramSize
		<> help "total size of annexed files to process"
		<> hidden
		)
	]
  where
	setsizelimit n = setAnnexState $ do
		v <- liftIO $ newTVarIO n
		Annex.changeState $ \s -> s { Annex.sizelimit = Just v }

data DaemonOptions = DaemonOptions
	{ foregroundDaemonOption :: Bool
	, stopDaemonOption :: Bool
	}

parseDaemonOptions :: Bool -> Parser DaemonOptions
parseDaemonOptions canstop
	| canstop = DaemonOptions <$> foreground <*> stop
	| otherwise = DaemonOptions <$> foreground <*> pure False
  where
	foreground = switch
		( long "foreground"
		<> help "do not daemonize"
		)
	stop = switch
		( long "stop"
		<> help "stop daemon"
		)

completeRemotes :: HasCompleter f => Mod f a
completeRemotes = completer $ mkCompleter $ \input -> do
	r <- maybe (pure Nothing) (Just <$$> Git.Config.read)
		=<< Git.Construct.fromCwd
	return $ filter (input `isPrefixOf`) $
		mapMaybe remoteKeyToRemoteName $
			filter isRemoteUrlKey $
				maybe [] (M.keys . config) r
		
completeBackends :: HasCompleter f => Mod f a
completeBackends = completeWith $
	map (decodeBS . formatKeyVariety . Backend.backendVariety) Backend.builtinList
