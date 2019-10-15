{- git-annex remote log, pure operations
 - 
 - Copyright 2011-2019 Joey Hess <id@joeyh.name>
 - 
 - Licensed under the GNU AGPL version 3 or higher.
 -}

module Logs.Remote.Pure (
	calcRemoteConfigMap,
	parseRemoteConfigLog,
	buildRemoteConfigLog,
        keyValToConfig,
        configToKeyVal,
        showConfig,

        prop_isomorphic_configEscape,
        prop_parse_show_Config,
) where

import Annex.Common
import Types.Remote
import Logs.UUIDBased
import Annex.SpecialRemote.Config

import qualified Data.ByteString.Lazy as L
import qualified Data.Map as M
import Data.Char
import qualified Data.Attoparsec.ByteString.Lazy as A
import Data.ByteString.Builder

calcRemoteConfigMap :: L.ByteString -> M.Map UUID RemoteConfig
calcRemoteConfigMap = (\m -> M.map (addSameasInherited m) m)
	. simpleMap
	. parseRemoteConfigLog

parseRemoteConfigLog :: L.ByteString -> Log RemoteConfig
parseRemoteConfigLog = parseLogOld remoteConfigParser

buildRemoteConfigLog :: Log RemoteConfig -> Builder
buildRemoteConfigLog = buildLogOld (byteString . encodeBS . showConfig)

remoteConfigParser :: A.Parser RemoteConfig
remoteConfigParser = keyValToConfig . words . decodeBS <$> A.takeByteString

showConfig :: RemoteConfig -> String
showConfig = unwords . configToKeyVal

{- Given Strings like "key=value", generates a RemoteConfig. -}
keyValToConfig :: [String] -> RemoteConfig
keyValToConfig ws = M.fromList $ map (/=/) ws
  where
	(/=/) s = (k, v)
	  where
		k = takeWhile (/= '=') s
		v = configUnEscape $ drop (1 + length k) s

configToKeyVal :: M.Map String String -> [String]
configToKeyVal m = map toword $ sort $ M.toList m
  where
	toword (k, v) = k ++ "=" ++ configEscape v

configEscape :: String -> String
configEscape = concatMap escape
  where
	escape c
		| isSpace c || c `elem` "&" = "&" ++ show (ord c) ++ ";"
		| otherwise = [c]

configUnEscape :: String -> String
configUnEscape = unescape
  where
	unescape [] = []
	unescape (c:rest)
		| c == '&' = entity rest
		| otherwise = c : unescape rest
	entity s
		| not (null num) && ";" `isPrefixOf` r =
			chr (Prelude.read num) : unescape rest
		| otherwise =
			'&' : unescape s
	  where
		num = takeWhile isNumber s
		r = drop (length num) s
		rest = drop 1 r

{- for quickcheck -}
prop_isomorphic_configEscape :: String -> Bool
prop_isomorphic_configEscape s = s == (configUnEscape . configEscape) s

prop_parse_show_Config :: RemoteConfig -> Bool
prop_parse_show_Config c
	-- whitespace and '=' are not supported in config keys
	| any (\k -> any isSpace k || elem '=' k) (M.keys c) = True
	| any (any excluded) (M.keys c) = True
	| any (any excluded) (M.elems c) = True
	| otherwise = A.parseOnly remoteConfigParser (encodeBS $ showConfig c) ~~ Right c
  where
	normalize v = sort . M.toList <$> v
	a ~~ b = normalize a == normalize b
	-- limit to ascii alphanumerics for simplicity; characters not
	-- allowed by the current character set in the config may not
	-- round-trip in an identical representation due to the use of the
	-- filesystem encoding.
	excluded ch = not (isAlphaNum ch) || not (isAscii ch)
