{- WebDAV remotes.
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE ScopedTypeVariables #-}

module Remote.WebDAV (remote, setCredsEnv) where

import Network.Protocol.HTTP.DAV
import qualified Data.Map as M
import qualified Data.ByteString.UTF8 as B8
import qualified Data.ByteString.Lazy.UTF8 as L8
import qualified Data.ByteString.Lazy as L
import qualified Data.Text as T
import qualified Text.XML as XML
import Network.URI (normalizePathSegments)
import qualified Control.Exception as E
import Network.HTTP.Conduit (HttpException(..))
import Network.HTTP.Types
import System.IO.Error

import Common.Annex
import Types.Remote
import qualified Git
import Config
import Remote.Helper.Special
import Remote.Helper.Encryptable
import Remote.Helper.Chunked
import Crypto
import Creds

type DavUrl = String
type DavUser = B8.ByteString
type DavPass = B8.ByteString

remote :: RemoteType
remote = RemoteType {
	typename = "webdav",
	enumerate = findSpecialRemotes "webdav",
	generate = gen,
	setup = webdavSetup
}

gen :: Git.Repo -> UUID -> Maybe RemoteConfig -> Annex Remote
gen r u c = do
	cst <- remoteCost r expensiveRemoteCost
	return $ gen' r u c cst
gen' :: Git.Repo -> UUID -> Maybe RemoteConfig -> Int -> Remote
gen' r u c cst =
	encryptableRemote c
		(storeEncrypted this)
		(retrieveEncrypted this)
		this
  where
	this = Remote {
		uuid = u,
		cost = cst,
		name = Git.repoDescribe r,
 		storeKey = store this,
		retrieveKeyFile = retrieve this,
		retrieveKeyFileCheap = retrieveCheap this,
		removeKey = remove this,
		hasKey = checkPresent this,
		hasKeyCheap = False,
		whereisKey = Nothing,
		config = c,
		repo = r,
		localpath = Nothing,
		readonly = False,
		remotetype = remote
	}

webdavSetup :: UUID -> RemoteConfig -> Annex RemoteConfig
webdavSetup u c = do
	let url = fromMaybe (error "Specify url=") $
		M.lookup "url" c
	c' <- encryptionSetup c
	creds <- getCreds c' u
	testDav url creds
	gitConfigSpecialRemote u c' "webdav" "true"
	setRemoteCredPair c' (davCreds u)

store :: Remote -> Key -> AssociatedFile -> MeterUpdate -> Annex Bool
store r k _f _p = davAction r False $ \(baseurl, user, pass) -> do
	let url = davLocation baseurl k
	f <- inRepo $ gitAnnexLocation k
	liftIO $ storeHelper r url user pass =<< L.readFile f

storeEncrypted :: Remote -> (Cipher, Key) -> Key -> MeterUpdate -> Annex Bool
storeEncrypted r (cipher, enck) k _p = davAction r False $ \(baseurl, user, pass) -> do
	let url = davLocation baseurl enck
	f <- inRepo $ gitAnnexLocation k
	liftIO $ withEncryptedContent cipher (L.readFile f) $
		storeHelper r url user pass

storeHelper :: Remote -> DavUrl -> DavUser -> DavPass -> L.ByteString -> IO Bool
storeHelper r urlbase user pass b = catchBoolIO $ do
	davMkdir (urlParent urlbase) user pass
	storeChunks urlbase chunksize storer recorder finalizer
  where
	chunksize = chunkSize $ config r
	storer urls = storeChunked chunksize urls storehttp b
	recorder url s = storehttp url (L8.fromString s)
	finalizer srcurl desturl = 
		moveContent srcurl (B8.fromString desturl) user pass
	storehttp url v = putContentAndProps url user pass
		(noProps, (contentType, v))

retrieveCheap :: Remote -> Key -> FilePath -> Annex Bool
retrieveCheap _ _ _ = return False

retrieve :: Remote -> Key -> AssociatedFile -> FilePath -> Annex Bool
retrieve r k _f d = metered Nothing k $ \meterupdate ->
	davAction r False $ \(baseurl, user, pass) -> liftIO $ catchBoolIO $
		withStoredFiles r k baseurl user pass onerr $ \urls -> do
			meteredWriteFileChunks meterupdate d urls $
				feeder user pass
			return True
  where
	onerr _ = return False

	feeder _ _ [] = return ([], [])
	feeder user pass (url:urls) = do
		mb <- davGetUrlContent url user pass
		case mb of
			Nothing -> throwIO "download failed"
			Just b -> return (urls, L.toChunks b)

retrieveEncrypted :: Remote -> (Cipher, Key) -> Key -> FilePath -> Annex Bool
retrieveEncrypted r (cipher, enck) k d = metered Nothing k $ \meterupdate ->
	davAction r False $ \(baseurl, user, pass) -> liftIO $ catchBoolIO $
		withStoredFiles r enck baseurl user pass onerr $ \urls -> do
			withDecryptedContent cipher (L.concat <$> feeder user pass urls []) $
				meteredWriteFile meterupdate d
			return True
  where
	onerr _ = return False

	feeder _ _ [] c = return $ reverse c
	feeder user pass (url:urls) c = do
		mb <- davGetUrlContent url user pass
		case mb of
			Nothing -> throwIO "download failed"
			Just b -> feeder user pass urls (b:c)

remove :: Remote -> Key -> Annex Bool
remove r k = davAction r False $ \(baseurl, user, pass) -> liftIO $ do
	-- Delete the key's whole directory, including any chunked
	-- files, etc, in a single action.
	let url = urlParent $ davLocation baseurl k
	isJust <$> catchMaybeHttp (deleteContent url user pass)

checkPresent :: Remote -> Key -> Annex (Either String Bool)
checkPresent r k = davAction r noconn go
  where
	noconn = Left $ error $ name r ++ " not configured"

	go (baseurl, user, pass) = do
		showAction $ "checking " ++ name r
		liftIO $ withStoredFiles r k baseurl user pass onerr check
	  where
		check [] = return $ Right True
		check (url:urls) = do
			v <- davUrlExists url user pass
			if v == Right True
				then check urls
				else return v

		{- Failed to read the chunkcount file; see if it's missing,
		 - or if there's a problem accessing it,
		 - or perhaps this was an intermittent error. -}
		onerr url = do
			v <- davUrlExists url user pass
			if v == Right True
				then return $ Left $ "failed to read " ++ url
				else return v

withStoredFiles
	:: Remote
	-> Key
	-> DavUrl
	-> DavUser
	-> DavPass
	-> (DavUrl -> IO a)
	-> ([DavUrl] -> IO a)
	-> IO a
withStoredFiles r k baseurl user pass onerr a
	| isJust $ chunkSize $ config r = do
		let chunkcount = url ++ chunkCount
		maybe (onerr chunkcount) (a . listChunks url . L8.toString)
			=<< davGetUrlContent chunkcount user pass
	| otherwise = a [url]
  where
	url = davLocation baseurl k

davAction :: Remote -> a -> ((DavUrl, DavUser, DavPass) -> Annex a) -> Annex a
davAction r unconfigured action = case config r of
	Nothing -> return unconfigured
	Just c -> do
		mcreds <- getCreds c (uuid r)
		case (mcreds, M.lookup "url" c) of
			(Just (user, pass), Just url) ->
				action (url, toDavUser user, toDavPass pass)
			_ -> return unconfigured

toDavUser :: String -> DavUser
toDavUser = B8.fromString

toDavPass :: String -> DavPass
toDavPass = B8.fromString

{- The location to use to store a Key. -}
davLocation :: DavUrl -> Key -> DavUrl
davLocation baseurl k = davUrl baseurl $ annexLocation k hashDirLower

davUrl :: DavUrl -> FilePath -> DavUrl
davUrl baseurl file = baseurl </> file

davUrlExists :: DavUrl -> DavUser -> DavPass -> IO (Either String Bool)
davUrlExists url user pass = decode <$> catchHttp (getProps url user pass)
  where
	decode (Right _) = Right True
	decode (Left (Left (StatusCodeException status _)))
		| statusCode status == statusCode notFound404 = Right False
	decode (Left e) = Left $ showEitherException e

davGetUrlContent :: DavUrl -> DavUser -> DavPass -> IO  (Maybe L.ByteString)
davGetUrlContent url user pass = fmap (snd . snd) <$>
	catchMaybeHttp (getPropsAndContent url user pass)

{- Creates a directory in WebDAV, if not already present; also creating
 - any missing parent directories. -}
davMkdir :: DavUrl -> DavUser -> DavPass -> IO ()
davMkdir url user pass = go url
  where
	make u = makeCollection u user pass

	go u = do
		r <- E.try (make u) :: IO (Either E.SomeException Bool)
		case r of
			{- Parent directory is missing. Recurse to create
			 - it, and try once more to create the directory. -}
			Right False -> do
				go (urlParent u)
				void $ make u
			{- Directory created successfully -}
			Right True -> return ()
			{- Directory already exists, or some other error
			 - occurred. In the latter case, whatever wanted
			 - to use this directory will fail. -}
			Left _ -> return ()

{- Catches HTTP and IO exceptions. -}
catchMaybeHttp :: IO a -> IO (Maybe a)
catchMaybeHttp a = (Just <$> a) `E.catches`
	[ E.Handler $ \(_e :: HttpException) -> return Nothing
	, E.Handler $ \(_e :: E.IOException) -> return Nothing
	]

{- Catches HTTP and IO exceptions -}
catchHttp :: IO a -> IO (Either EitherException a)
catchHttp a = (Right <$> a) `E.catches`
	[ E.Handler $ \(e :: HttpException) -> return $ Left $ Left e
	, E.Handler $ \(e :: E.IOException) -> return $ Left $ Right e
	]

type EitherException = Either HttpException E.IOException

showEitherException :: EitherException -> String
showEitherException (Left (StatusCodeException status _)) = show $ statusMessage status
showEitherException (Left httpexception) = show httpexception
showEitherException (Right ioexception) = show ioexception

throwIO :: String -> IO a
throwIO msg = ioError $ mkIOError userErrorType msg Nothing Nothing

urlParent :: DavUrl -> DavUrl
urlParent url = reverse $ dropWhile (== '/') $ reverse $
	normalizePathSegments (url ++ "/..")

{- Test if a WebDAV store is usable, by writing to a test file, and then
 - deleting the file. Exits with an IO error if not. -}
testDav :: String -> Maybe CredPair -> Annex ()
testDav baseurl (Just (u, p)) = do
	showSideAction "testing WebDAV server"
	liftIO $ either (throwIO . showEitherException) (const noop)
		=<< catchHttp go
  where
	go = do
		davMkdir baseurl user pass
		putContentAndProps testurl user pass
			(noProps, (contentType, L.empty))
		deleteContent testurl user pass

	user = toDavUser u
	pass = toDavPass p
	testurl = davUrl baseurl "git-annex-test"
testDav _ Nothing = error "Need to configure webdav username and password."

{- Content-Type to use for files uploaded to WebDAV. -}
contentType :: Maybe B8.ByteString
contentType = Just $ B8.fromString "application/octet-stream"

{- The DAV library requires that properties be specified when storing a file.
 - This just omits any real properties. -}
noProps :: XML.Document
noProps = XML.Document (XML.Prologue [] Nothing []) root []
  where
    root = XML.Element (XML.Name (T.pack "propertyupdate") Nothing Nothing) [] []

getCreds :: RemoteConfig -> UUID -> Annex (Maybe CredPair)
getCreds c u = maybe missing (return . Just) =<< getRemoteCredPair c creds
  where
	creds = davCreds u
	(loginvar, passwordvar) = credPairEnvironment creds
	missing = do
		warning $ "Set both " ++ loginvar ++ " and " ++ passwordvar ++ " to use webdav"
		return Nothing

davCreds :: UUID -> CredPairStorage
davCreds u = CredPairStorage
        { credPairFile = fromUUID u
        , credPairEnvironment = ("WEBDAV_USERNAME", "WEBDAV_PASSWORD")
        , credPairRemoteKey = Just "davcreds"
        }

setCredsEnv :: (String, String) -> IO ()
setCredsEnv creds = setEnvCredPair creds $ davCreds undefined
