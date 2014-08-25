--------------------------------------------------------------------------------
-- |
-- Module : Data.Rakhana
-- Copyright : (C) 2014 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
--------------------------------------------------------------------------------
module Data.Rakhana where

--------------------------------------------------------------------------------
import Control.Monad.Trans

--------------------------------------------------------------------------------
import Data.Rakhana.Internal.Types
import Data.Rakhana.Tape
import Data.Rakhana.Nursery
import Pipes

--------------------------------------------------------------------------------
user :: MonadIO m => Playground m ()
user = do doc  <- nurseryGetDocument
          info <- nurseryGetInfo

          liftIO $ print doc
          liftIO $ print info

app :: IO ()
app = runDrive (fileTape "samples/IdiomLite.pdf") (withNursery user)
