{- git-annex command
 -
 - Copyright 2010,2016 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Command.DropKey where

import Command
import qualified Annex
import Logs.Location
import Annex.Content

cmd :: Command
cmd = noCommit $ withGlobalOptions [jsonOptions] $
	command "dropkey" SectionPlumbing
		"drops annexed content for specified keys"
		(paramRepeating paramKey)
		(seek <$$> optParser)

data DropKeyOptions = DropKeyOptions
	{ toDrop :: [String]
	, batchOption :: BatchMode
	}

optParser :: CmdParamsDesc -> Parser DropKeyOptions
optParser desc = DropKeyOptions
	<$> cmdParams desc
	<*> parseBatchOption False

seek :: DropKeyOptions -> CommandSeek
seek o = do
	unlessM (Annex.getState Annex.force) $
		giveup "dropkey can cause data loss; use --force if you're sure you want to do this"
	withKeys (commandAction . start) (toDrop o)
	case batchOption o of
		Batch fmt -> batchInput fmt (pure . parsekey) $
			batchCommandAction . start
		NoBatch -> noop
  where
	parsekey = maybe (Left "bad key") Right . deserializeKey

start :: (SeekInput, Key) -> CommandStart
start (si, key) = starting "dropkey" (mkActionItem key) si $
	perform key

perform :: Key -> CommandPerform
perform key = ifM (inAnnex key)
	( lockContentForRemoval key (next $ cleanup key) $ \contentlock -> do
		removeAnnex contentlock
		next $ cleanup key
	, next $ return True
	)

cleanup :: Key -> CommandCleanup
cleanup key = do
	logStatus key InfoMissing
	return True
