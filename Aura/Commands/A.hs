-- Handles all `-A` operations

{-

Copyright 2012, 2013 Colin Woodbury <colingw@gmail.com>

This file is part of Aura.

Aura is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Aura is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Aura.  If not, see <http://www.gnu.org/licenses/>.

-}

module Aura.Commands.A
    ( installPackages
    , upgradeAURPkgs
    , aurPkgInfo
    , aurSearch
    , displayPkgDeps
    , downloadTarballs
    , displayPkgbuild ) where

import Text.Regex.PCRE ((=~))
import Control.Monad   (unless, liftM)
import Data.List       ((\\), nub, nubBy, sort)

import Aura.Pacman (pacman)
import Aura.Pkgbuild.Records
import Aura.Pkgbuild.Editing
import Aura.Settings.Base
import Aura.Dependencies
import Aura.Colour.Text
import Aura.Monad.Aura
import Aura.Languages
import Aura.Build
import Aura.Utils
import Aura.Core
import Aura.AUR

import Shell

---

type PBHandler = [AURPkg] -> Aura [AURPkg]

-- | The user can handle PKGBUILDs in multiple ways.
-- `--hotedit` takes the highest priority.
pbHandler :: Aura PBHandler
pbHandler = ask >>= check
    where check ss | mayHotEdit ss      = return hotEdit
                   | useCustomizepkg ss = return customizepkg
                   | otherwise          = return return

installPackages :: [String] -> [String] -> Aura ()
installPackages _ []         = return ()
installPackages pacOpts pkgs = ask >>= \ss ->
  if not $ delMakeDeps ss
     then installPackages' pacOpts pkgs
     else do  -- `-a` was used with `-A`.
       orphansBefore <- getOrphans
       installPackages' pacOpts pkgs
       orphansAfter <- getOrphans
       let makeDeps = orphansAfter \\ orphansBefore
       unless (null makeDeps) $ notify removeMakeDepsAfter_1
       removePkgs makeDeps pacOpts

installPackages' :: [String] -> [String] -> Aura ()
installPackages' pacOpts pkgs = ask >>= \ss -> do
  let toInstall = pkgs \\ ignoredPkgsOf ss
      ignored   = pkgs \\ toInstall
  reportIgnoredPackages ignored
  (_,aur,nons) <- knownBadPkgCheck toInstall >>= divideByPkgType ignoreRepos
  reportNonPackages nons
  handler <- pbHandler
  aurPkgs <- mapM aurPkg aur >>= reportPkgbuildDiffs >>= handler
  notify installPackages_5
  (repoDeps,aurDeps) <- catch (getDepsToInstall aurPkgs) depCheckFailure
  let repoPkgs    = nub repoDeps
      pkgsAndOpts = pacOpts ++ repoPkgs
  reportPkgsToInstall repoPkgs aurDeps aurPkgs
  okay <- optionalPrompt installPackages_3
  if not okay
     then scoldAndFail installPackages_4
     else do
       unless (null repoPkgs) $ pacman (["-S","--asdeps"] ++ pkgsAndOpts)
       storePkgbuilds $ aurPkgs ++ aurDeps
       mapM_ (buildAndInstallDep handler pacOpts) aurDeps
       buildPackages aurPkgs >>= installPkgFiles pacOpts

knownBadPkgCheck :: [String] -> Aura [String]
knownBadPkgCheck []     = return []
knownBadPkgCheck (p:ps) = ask >>= \ss ->
  case p `lookup` wontBuildOf ss of
    Nothing -> (p :) `liftM` knownBadPkgCheck ps
    Just r  -> do
      scold $ knownBadPkgCheck_1 p
      putStrLnA yellow r
      okay <- optionalPrompt knownBadPkgCheck_2
      if okay then (p :) `liftM` knownBadPkgCheck ps else knownBadPkgCheck ps

depCheckFailure :: String -> Aura a
depCheckFailure m = scold installPackages_1 >> failure m

buildAndInstallDep :: PBHandler -> [String] -> AURPkg -> Aura ()
buildAndInstallDep handler pacOpts pkg =
  handler [pkg] >>= buildPackages >>=
  installPkgFiles ("--asdeps" : pacOpts)

upgradeAURPkgs :: [String] -> [String] -> Aura ()
upgradeAURPkgs pacOpts pkgs = ask >>= \ss -> do
  let notIgnored p = splitName p `notElem` ignoredPkgsOf ss
  notify upgradeAURPkgs_1
  foreignPkgs <- filter (\(n,_) -> notIgnored n) `liftM` getForeignPackages
  pkgInfo     <- aurInfoLookup $ map fst foreignPkgs
  let aurPkgs   = filter (\(n,_) -> n `elem` map nameOf pkgInfo) foreignPkgs
      toUpgrade = filter isntMostRecent $ zip pkgInfo (map snd aurPkgs)
  devel <- develPkgCheck
  notify upgradeAURPkgs_2
  if null toUpgrade && null devel
     then warn upgradeAURPkgs_3
     else reportPkgsToUpgrade $ map prettify toUpgrade ++ devel
  installPackages pacOpts $ map (nameOf . fst) toUpgrade ++ pkgs ++ devel
    where prettify (p,v) = nameOf p ++ " : " ++ v ++ " => " ++ latestVerOf p

develPkgCheck :: Aura [String]
develPkgCheck = ask >>= \ss ->
  if rebuildDevel ss then getDevelPkgs else return []

aurPkgInfo :: [String] -> Aura ()
aurPkgInfo pkgs = aurInfoLookup pkgs >>= mapM_ displayAurPkgInfo

displayAurPkgInfo :: PkgInfo -> Aura ()
displayAurPkgInfo info = ask >>= \ss ->
    liftIO $ putStrLn $ renderAurPkgInfo ss info ++ "\n"

renderAurPkgInfo :: Settings -> PkgInfo -> String
renderAurPkgInfo ss info = entrify ss fields entries
    where fields  = map white . infoFields . langOf $ ss
          entries = [ magenta "aur"
                    , white $ nameOf info
                    , latestVerOf info
                    , outOfDateMsg (isOutOfDate info) $ langOf ss
                    , cyan $ projectURLOf info
                    , aurURLOf info
                    , licenseOf info
                    , yellow . show . votesOf $ info
                    , descriptionOf info ]

aurSearch :: [String] -> Aura ()
aurSearch []    = return ()
aurSearch regex = do
    results <- aurSearchLookup regex
    mapM_ (liftIO . putStrLn . renderSearch (unwords regex)) results

renderSearch :: String -> PkgInfo -> String
renderSearch r i = repo ++ n ++ " " ++ v ++ " (" ++ l ++ ")\n    " ++ d
    where c cl cs = case cs =~ ("(?i)" ++ r) of
                      (b,m,a) -> cl b ++ bCyan m ++ cl a
          repo = magenta "aur/"
          n = c bForeground $ nameOf i
          d = c noColour $ descriptionOf i
          l = yellow . show . votesOf $ i  -- `l` for likes?
          v | isOutOfDate i = red $ latestVerOf i
            | otherwise     = green $ latestVerOf i

displayPkgDeps :: [String] -> Aura ()
displayPkgDeps []   = return ()
displayPkgDeps pkgs = do
  info    <- aurInfoLookup pkgs
  aurPkgs <- mapM (aurPkg . nameOf) info
  allDeps <- mapM determineDeps aurPkgs
  let (ps,as,_) = foldl groupPkgs ([],[],[]) allDeps
  reportPkgsToInstall (n ps) (nubBy sameName as) []
    where n = nub . map splitName
          sameName a b = pkgNameOf a == pkgNameOf b

downloadTarballs :: [String] -> Aura ()
downloadTarballs pkgs = do
  currDir <- liftIO pwd
  filterAURPkgs pkgs >>= mapM_ (downloadTBall currDir)
    where downloadTBall path pkg = do
              notify $ downloadTarballs_1 pkg
              liftIO $ sourceTarball path pkg

displayPkgbuild :: [String] -> Aura ()
displayPkgbuild pkgs = filterAURPkgs pkgs >>= mapM_ dnload
      where dnload p = downloadPkgbuild p >>= liftIO . putStrLn

------------
-- REPORTING
------------
reportPkgsToInstall :: [String] -> [AURPkg] -> [AURPkg] -> Aura ()
reportPkgsToInstall pacPkgs aurDeps aurPkgs = do
  lang <- langOf `liftM` ask
  pl (reportPkgsToInstall_1 lang) (sort pacPkgs)
  pl (reportPkgsToInstall_2 lang) (sort $ namesOf aurDeps)
  pl (reportPkgsToInstall_3 lang) (sort $ namesOf aurPkgs)
      where namesOf = map pkgNameOf
            pl      = printList green cyan

reportNonPackages :: [String] -> Aura ()
reportNonPackages = badReport reportNonPackages_1

reportIgnoredPackages :: [String] -> Aura ()
reportIgnoredPackages pkgs = do
  lang <- langOf `liftM` ask
  printList yellow cyan (reportIgnoredPackages_1 lang) pkgs

reportPkgbuildDiffs :: [AURPkg] -> Aura [AURPkg]
reportPkgbuildDiffs [] = return []
reportPkgbuildDiffs ps = ask >>= check
    where check ss | not $ diffPkgbuilds ss = return ps
                   | otherwise = mapM_ displayDiff ps >> return ps
          displayDiff p = do
            let name = pkgNameOf p
            isStored <- hasPkgbuildStored name
            if not isStored
               then warn $ reportPkgbuildDiffs_1 name
               else do
                 let new = pkgbuildOf p
                 old <- readPkgbuild name
                 case comparePkgbuilds old new of
                   "" -> notify $ reportPkgbuildDiffs_2 name
                   d  -> do
                      warn $ reportPkgbuildDiffs_3 name
                      liftIO $ putStrLn $ d ++ "\n"

reportPkgsToUpgrade :: [String] -> Aura ()
reportPkgsToUpgrade pkgs = do
  lang <- langOf `liftM` ask
  printList green cyan (reportPkgsToUpgrade_1 lang) pkgs
