{- git-annex object content presence
 -
 - Copyright 2010-2021 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}

module Annex.Content.Presence (
	inAnnex,
	inAnnex',
	inAnnexSafe,
	inAnnexCheck,
	objectFileExists,
	withObjectLoc,
	isUnmodified,
	isUnmodified',
	isUnmodifiedCheap,
	contentLockFile,
) where

import Annex.Content.Presence.LowLevel
import Annex.Common
import qualified Annex
import Annex.LockPool
import qualified Database.Keys
import Annex.InodeSentinal
import Utility.InodeCache
import qualified Utility.RawFilePath as R

#ifdef mingw32_HOST_OS
import Annex.Perms
#endif

{- Checks if a given key's content is currently present. -}
inAnnex :: Key -> Annex Bool
inAnnex key = inAnnexCheck key $ liftIO . R.doesPathExist

{- Runs an arbitrary check on a key's content. -}
inAnnexCheck :: Key -> (RawFilePath -> Annex Bool) -> Annex Bool
inAnnexCheck key check = inAnnex' id False check key

{- inAnnex that performs an arbitrary check of the key's content. -}
inAnnex' :: (a -> Bool) -> a -> (RawFilePath -> Annex a) -> Key -> Annex a
inAnnex' isgood bad check key = withObjectLoc key $ \loc -> do
	r <- check loc
	if isgood r
		then ifM (annexThin <$> Annex.getGitConfig)
			-- When annex.thin is set, the object file
			-- could be modified; make sure it's not.
			-- (Suppress any messages about
			-- checksumming, to avoid them cluttering
			-- the display.)
			( ifM (doQuietAction $ isUnmodified key loc)
				( return r
				, return bad
				)
			, return r
			)
		else return bad

{- Like inAnnex, checks if the object file for a key exists,
 - but there are no guarantees it has the right content. -}
objectFileExists :: Key -> Annex Bool
objectFileExists key =
	calcRepo (gitAnnexLocation key)
		>>= liftIO . R.doesPathExist

{- A safer check; the key's content must not only be present, but
 - is not in the process of being removed. -}
inAnnexSafe :: Key -> Annex (Maybe Bool)
inAnnexSafe key = inAnnex' (fromMaybe True) (Just False) go key
  where
	is_locked = Nothing
	is_unlocked = Just True
	is_missing = Just False

	go contentfile = flip checklock contentfile =<< contentLockFile key

#ifndef mingw32_HOST_OS
	checklock Nothing contentfile = checkOr is_missing contentfile
	{- The content file must exist, but the lock file generally
	 - won't exist unless a removal is in process. -}
	checklock (Just lockfile) contentfile =
		ifM (liftIO $ doesFileExist (fromRawFilePath contentfile))
			( checkOr is_unlocked lockfile
			, return is_missing
			)
	checkOr d lockfile = checkLocked lockfile >>= return . \case
		Nothing -> d
		Just True -> is_locked
		Just False -> is_unlocked
#else
	checklock Nothing contentfile = liftIO $ ifM (doesFileExist (fromRawFilePath contentfile))
		( lockShared contentfile >>= \case
			Nothing -> return is_locked
			Just lockhandle -> do
				dropLock lockhandle
				return is_unlocked
		, return is_missing
		)
	{- In Windows, see if we can take a shared lock. If so, 
	 - remove the lock file to clean up after ourselves. -}
	checklock (Just lockfile) contentfile =
		ifM (liftIO $ doesFileExist (fromRawFilePath contentfile))
			( modifyContent lockfile $ liftIO $
				lockShared lockfile >>= \case
					Nothing -> return is_locked
					Just lockhandle -> do
						dropLock lockhandle
						void $ tryIO $ removeWhenExistsWith R.removeLink lockfile
						return is_unlocked
			, return is_missing
			)
#endif

{- Windows has to use a separate lock file from the content, since
 - locking the actual content file would interfere with the user's
 - use of it. -}
contentLockFile :: Key -> Annex (Maybe RawFilePath)
#ifndef mingw32_HOST_OS
contentLockFile _ = pure Nothing
#else
contentLockFile key = Just <$> calcRepo (gitAnnexContentLock key)
#endif

{- Performs an action, passing it the location to use for a key's content. -}
withObjectLoc :: Key -> (RawFilePath -> Annex a) -> Annex a
withObjectLoc key a = a =<< calcRepo (gitAnnexLocation key)

{- Check if a file contains the unmodified content of the key.
 -
 - The expensive way to tell is to do a verification of its content.
 - The cheaper way is to see if the InodeCache for the key matches the
 - file. -}
isUnmodified :: Key -> RawFilePath -> Annex Bool
isUnmodified key f = 
	withTSDelta (liftIO . genInodeCache f) >>= \case
		Just fc -> do
			ic <- Database.Keys.getInodeCaches key
			isUnmodified' key f fc ic
		Nothing -> return False

isUnmodified' :: Key -> RawFilePath -> InodeCache -> [InodeCache] -> Annex Bool
isUnmodified' = isUnmodifiedLowLevel Database.Keys.addInodeCaches

{- Cheap check if a file contains the unmodified content of the key,
 - only checking the InodeCache of the key.
 -
 - When the InodeCache is stale, this may incorrectly report that a file is
 - modified.
 -
 - Note that, on systems not supporting high-resolution mtimes,
 - this may report a false positive when repeated edits are made to a file
 - within a small time window (eg 1 second).
 -}
isUnmodifiedCheap :: Key -> RawFilePath -> Annex Bool
isUnmodifiedCheap key f = maybe (return False) (isUnmodifiedCheap' key) 
	=<< withTSDelta (liftIO . genInodeCache f)

isUnmodifiedCheap' :: Key -> InodeCache -> Annex Bool
isUnmodifiedCheap' key fc = isUnmodifiedCheapLowLevel fc
	=<< Database.Keys.getInodeCaches key
