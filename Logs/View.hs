{- git-annex recent views log
 -
 - The most recently accessed view comes first.
 -
 - This file is stored locally in .git/annex/, not in the git-annex branch.
 -
 - Copyright 2014 Joey Hess <id@joeyh.name>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE OverloadedStrings #-}

module Logs.View (
	currentView,
	setView,
	removeView,
	recentViews,
	branchView,
	is_branchView,
	prop_branchView_legal,
) where

import Annex.Common
import Types.View
import Types.MetaData
import qualified Git
import qualified Git.Branch
import qualified Git.Ref
import Git.Types
import Logs.File

import qualified Data.Text as T
import qualified Data.Set as S
import Data.Char
import qualified Data.ByteString as B

setView :: View -> Annex ()
setView v = do
	old <- take 99 . filter (/= v) <$> recentViews
	writeViews (v : old)

writeViews :: [View] -> Annex ()
writeViews l = do
	f <- fromRepo gitAnnexViewLog
	writeLogFile f $ unlines $ map show l

removeView :: View -> Annex ()
removeView v = writeViews =<< filter (/= v) <$> recentViews

recentViews :: Annex [View]
recentViews = do
	f <- fromRawFilePath <$> fromRepo gitAnnexViewLog
	liftIO $ mapMaybe readish . lines <$> catchDefaultIO [] (readFile f)

{- Gets the currently checked out view, if there is one. -}
currentView :: Annex (Maybe View)
currentView = go =<< inRepo Git.Branch.current
  where
	go (Just b) | branchViewPrefix `B.isPrefixOf` fromRef' b =
		headMaybe . filter (\v -> branchView v == b) <$> recentViews
	go _ = return Nothing

branchViewPrefix :: B.ByteString
branchViewPrefix = "refs/heads/views"

{- Generates a git branch name for a View.
 - 
 - There is no guarantee that each view gets a unique branch name,
 - but the branch name is used to express the view as well as possible.
 -}
branchView :: View -> Git.Branch
branchView view
	| B.null name = Git.Ref branchViewPrefix
	| otherwise = Git.Ref $ branchViewPrefix <> "/" <> name
  where
	name = encodeBS $
		intercalate ";" $ map branchcomp (viewComponents view)
	branchcomp c
		| viewVisible c = branchcomp' c
		| otherwise = "(" ++ branchcomp' c ++ ")"
	branchcomp' (ViewComponent metafield viewfilter _) = concat
		[ forcelegal (T.unpack (fromMetaField metafield))
		, branchvals viewfilter
		]
	branchvals (FilterValues set) = '=' : branchset set
	branchvals (FilterGlob glob) = '=' : forcelegal glob
	branchvals (ExcludeValues set) = "!=" ++ branchset set
	branchset = intercalate ","
		. map (forcelegal . decodeBS . fromMetaValue)
		. S.toList
	forcelegal s
		| Git.Ref.legal True s = s
		| otherwise = map (\c -> if isAlphaNum c then c else '_') s

is_branchView :: Git.Branch -> Bool
is_branchView (Ref b)
	| b == branchViewPrefix = True
	| otherwise = (branchViewPrefix <> "/") `B.isPrefixOf` b

prop_branchView_legal :: View -> Bool
prop_branchView_legal = Git.Ref.legal False . fromRef . branchView
