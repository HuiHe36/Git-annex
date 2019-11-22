{- git-annex database benchmarks
 -
 - Copyright 2016-2019 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Database.Benchmark (benchmarkDbs) where

import Annex.Common
import Types.Benchmark
#ifdef WITH_BENCHMARK
import qualified Database.Keys.SQL as SQL
import qualified Database.Queue as H
import Database.Init
import Database.Types
import Utility.Tmp.Dir
import Git.FilePath
import Types.Key
import Utility.DataUnits

import Criterion.Main
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Char8 as B8
import System.Random
#endif

benchmarkDbs :: CriterionMode -> Integer -> Annex ()
#ifdef WITH_BENCHMARK
benchmarkDbs mode n = withTmpDirIn "." "benchmark" $ \tmpdir -> do
	db <- benchDb tmpdir n
	liftIO $ runMode mode
		[ bgroup "keys database"
			[ getAssociatedFilesHitBench db
			, getAssociatedFilesMissBench db
			, getAssociatedKeyHitBench db
			, getAssociatedKeyMissBench db
			, addAssociatedFileOldBench db
			, addAssociatedFileNewBench db
			]
		]
#else
benchmarkDbs _ = error "not built with criterion, cannot benchmark"
#endif

#ifdef WITH_BENCHMARK

getAssociatedFilesHitBench :: BenchDb -> Benchmark
getAssociatedFilesHitBench (BenchDb h num) = bench ("getAssociatedFiles (hit)") $ nfIO $ do
	n <- getStdRandom (randomR (1,num))
	SQL.getAssociatedFiles (toIKey (keyN n)) (SQL.ReadHandle h)

getAssociatedFilesMissBench :: BenchDb -> Benchmark
getAssociatedFilesMissBench (BenchDb h _num) = bench ("getAssociatedFiles (miss)") $ nfIO $
	SQL.getAssociatedFiles (toIKey keyMiss) (SQL.ReadHandle h)

getAssociatedKeyHitBench :: BenchDb -> Benchmark
getAssociatedKeyHitBench (BenchDb h num) = bench ("getAssociatedKey (hit)") $ nfIO $ do
	n <- getStdRandom (randomR (1,num))
	-- fromIKey because this ends up being used to get a Key
	map fromIKey <$> SQL.getAssociatedKey (fileN n) (SQL.ReadHandle h)

getAssociatedKeyMissBench :: BenchDb -> Benchmark
getAssociatedKeyMissBench (BenchDb h _num) = bench ("getAssociatedKey from (miss)") $ nfIO $
	-- fromIKey because this ends up being used to get a Key
	map fromIKey <$> SQL.getAssociatedKey fileMiss (SQL.ReadHandle h)

addAssociatedFileOldBench :: BenchDb -> Benchmark
addAssociatedFileOldBench (BenchDb h num) = bench ("addAssociatedFile to (old)") $ nfIO $ do
	n <- getStdRandom (randomR (1,num))
	SQL.addAssociatedFile (toIKey (keyN n)) (fileN n) (SQL.WriteHandle h)
	H.flushDbQueue h

addAssociatedFileNewBench :: BenchDb -> Benchmark
addAssociatedFileNewBench (BenchDb h num) = bench ("addAssociatedFile to (new)") $ nfIO $ do
	n <- getStdRandom (randomR (1,num))
	SQL.addAssociatedFile (toIKey (keyN n)) (fileN (num+n)) (SQL.WriteHandle h)
	H.flushDbQueue h

populateAssociatedFiles :: H.DbQueue -> Integer -> IO ()
populateAssociatedFiles h num = do
	forM_ [1..num] $ \n ->
		SQL.addAssociatedFile (toIKey (keyN n)) (fileN n) (SQL.WriteHandle h)
	H.flushDbQueue h

keyN :: Integer -> Key
keyN n = mkKey $ \k -> k
	{ keyName = B8.pack $ "key" ++ show n
	, keyVariety = OtherKey "BENCH"
	}

fileN :: Integer -> TopFilePath
fileN n = asTopFilePath ("file" ++ show n)

keyMiss :: Key
keyMiss = keyN 0 -- 0 is never stored

fileMiss :: TopFilePath
fileMiss = fileN 0 -- 0 is never stored

data BenchDb = BenchDb H.DbQueue Integer

benchDb :: FilePath -> Integer -> Annex BenchDb
benchDb tmpdir num = do
	liftIO $ putStrLn $ "setting up database with " ++ show num ++ " items"
	initDb db SQL.createTables
	h <- liftIO $ H.openDbQueue H.MultiWriter db SQL.containedTable
	liftIO $ populateAssociatedFiles h num
	sz <- liftIO $ getFileSize db
	liftIO $ putStrLn $ "size of database on disk: " ++ 
		roughSize storageUnits False sz
	return (BenchDb h num)
  where
	db = tmpdir </> show num </> "db"

#endif /* WITH_BENCHMARK */
