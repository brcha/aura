-- Interface to `makepkg`.

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

module Aura.MakePkg
    ( makepkgQuiet
    , makepkgVerbose
    , makepkgConfFile ) where

import Control.Monad (liftM)
import Text.Regex.PCRE ((=~))

import Aura.Monad.Aura
import Aura.Shell (shellCmd, quietShellCmd', checkExitCode')

import Shell (pwd, ls)

---

makepkgConfFile :: FilePath
makepkgConfFile = "/etc/makepkg.conf"

-- Builds a package with `makepkg`.
-- Some packages create multiple .pkg.tar files. These are all returned.
makepkgGen :: (String -> [String] -> Aura a) -> String -> Aura [FilePath]
makepkgGen f user =
    f cmd opts >> filter (=~ ".pkg.tar") `liftM` liftIO (pwd >>= ls)
      where (cmd,opts) = determineRunStyle user

determineRunStyle :: String -> (String,[String])
determineRunStyle "root" = ("makepkg",["--asroot"])
determineRunStyle user   = ("su",[user,"-c","makepkg"])

makepkgQuiet :: String -> Aura [FilePath]
makepkgQuiet user = makepkgGen quiet user
    where quiet cmd opts = do
            (status,out,err) <- quietShellCmd' cmd opts
            let output = err ++ "\n" ++ out
            checkExitCode' output status

makepkgVerbose :: String -> Aura [FilePath]
makepkgVerbose user = makepkgGen shellCmd user
