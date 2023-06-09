{- git-annex command
 -
 - Copyright 2010-2018 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Command.Find where

import Data.Default
import qualified Data.Map as M
import qualified Data.ByteString as S
import qualified Data.ByteString.Short as S (fromShort)
import qualified Data.ByteString.Char8 as S8

import Command
import Limit
import Types.Key
import Git.FilePath
import qualified Utility.Format
import Utility.DataUnits

cmd :: Command
cmd = notBareRepo $ withGlobalOptions [annexedMatchingOptions] $ mkCommand $
	command "find" SectionQuery "lists available files"
		paramPaths (seek <$$> optParser)

mkCommand :: Command -> Command
mkCommand = noCommit . noMessages . withGlobalOptions [jsonOptions]

data FindOptions = FindOptions
	{ findThese :: CmdParams
	, formatOption :: Maybe Utility.Format.Format
	, keyOptions :: Maybe KeyOptions
	, batchOption :: BatchMode
	}

optParser :: CmdParamsDesc -> Parser FindOptions
optParser desc = FindOptions
	<$> cmdParams desc
	<*> optional parseFormatOption
	<*> optional parseBranchKeysOption
	<*> parseBatchOption False

parseFormatOption :: Parser Utility.Format.Format
parseFormatOption = 
	option (Utility.Format.gen <$> str)
		( long "format" <> metavar paramFormat
		<> help "control format of output"
		)
	<|> flag' (Utility.Format.gen "${file}\0")
		( long "print0"
		<> help "output filenames terminated with nulls"
		)

seek :: FindOptions -> CommandSeek
seek o = do
	islimited <- limited
	let seeker = AnnexedFileSeeker
		{ startAction = start o
		-- only files with content present are shown, unless
		-- the user has requested others via a limit
		, checkContentPresent = if islimited
			then Nothing
			else Just True
		, usesLocationLog = False
		}
	case batchOption o of
		NoBatch -> withKeyOptions (keyOptions o) False seeker
			(commandAction . startKeys o)
			(withFilesInGitAnnex ww seeker)
			=<< workTreeItems ww (findThese o)
		Batch fmt -> batchOnly (keyOptions o) (findThese o) $
			batchAnnexedFiles fmt seeker
  where
	ww = WarnUnmatchLsFiles

start :: FindOptions -> SeekInput -> RawFilePath -> Key -> CommandStart
start o _ file key = startingCustomOutput key $ do
	showFormatted (formatOption o) file 
		(formatVars key (AssociatedFile (Just file)))
	next $ return True

startKeys :: FindOptions -> (SeekInput, Key, ActionItem) -> CommandStart
startKeys o (si, key, ActionItemBranchFilePath (BranchFilePath _ topf) _) = 
	start o si (getTopFilePath topf) key
startKeys _ _ = stop

showFormatted :: Maybe Utility.Format.Format -> S.ByteString -> [(String, String)] -> Annex ()
showFormatted format unformatted vars =
	unlessM (showFullJSON $ JSONChunk vars) $
		case format of
			Nothing -> liftIO $ S8.putStrLn unformatted
			Just formatter -> liftIO $ putStr $
				Utility.Format.format formatter $
					M.fromList vars

formatVars :: Key -> AssociatedFile -> [(String, String)]
formatVars key (AssociatedFile af) =
	(maybe id (\f l -> (("file", fromRawFilePath f) : l)) af)
	[ ("key", serializeKey key)
	, ("backend", decodeBS $ formatKeyVariety $ fromKey keyVariety key)
	, ("bytesize", size show)
	, ("humansize", size $ roughSize storageUnits True)
	, ("keyname", decodeBS $ S.fromShort $ fromKey keyName key)
	, ("hashdirlower", fromRawFilePath $ hashDirLower def key)
	, ("hashdirmixed", fromRawFilePath $ hashDirMixed def key)
	, ("mtime", whenavail show $ fromKey keyMtime key)
	]
  where
	size c = whenavail c $ fromKey keySize key
	whenavail = maybe "unknown"
