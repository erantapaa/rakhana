{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
--------------------------------------------------------------------------------
-- |
-- Module : Data.Rakhana.Nursery
-- Copyright : (C) 2014 Yorick Laupa
-- License : (see the file LICENSE)
--
-- Maintainer : Yorick Laupa <yo.eight@gmail.com>
-- Stability : provisional
-- Portability : non-portable
--
--------------------------------------------------------------------------------
module Data.Rakhana.Nursery
    ( Document
    , Playground
    , nurseryGetDocument
    , nurseryGetInfo
    , withNursery
    ) where

--------------------------------------------------------------------------------
import           Control.Applicative
import           Data.ByteString
import qualified Data.Map.Strict as M
import           Data.Traversable (forM)
import           Data.Typeable hiding (Proxy)

--------------------------------------------------------------------------------
import Control.Lens
import Control.Monad.Catch (Exception, MonadThrow(..))
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Data.Attoparsec.ByteString
import Pipes hiding (Effect)
import Pipes.Core

--------------------------------------------------------------------------------
import Data.Rakhana.Internal.Parsers
import Data.Rakhana.Internal.Types
import Data.Rakhana.Tape
import Data.Rakhana.Util.Dictionary
import Data.Rakhana.Util.Drive
import Data.Rakhana.XRef

--------------------------------------------------------------------------------
data NurseryException
    = NurseryParsingException String
    | NurseryUnresolvedObject Int Int
    | NurseryRootNotFound
    | NurseryPagesNotFound
    | NurseryInvalidDocument
    deriving (Show, Typeable)

--------------------------------------------------------------------------------
type Nursery m a = Proxy Req Resp NReq NResp m a
type Playground m a = Client' NReq NResp m a
type Root = Dictionary
type Pages = Dictionary

--------------------------------------------------------------------------------
data NReq
    = RqDoc
    | RqInfo

--------------------------------------------------------------------------------
data NResp
    = Unit
    | RDoc Document
    | RInfo Dictionary

--------------------------------------------------------------------------------
instance Exception NurseryException

--------------------------------------------------------------------------------
data NurseryState
    = NurseryState
      { nurseryXRef  :: !XRef
      , nurseryRoot  :: !Dictionary
      , nurseryInfo  :: !Dictionary
      , nurseryPages :: !Dictionary
      , nurseryDoc   :: !Document
      }

--------------------------------------------------------------------------------
data Document
    = Document
      { docPageCount :: !Integer
      , docWidth     :: !Integer
      , docHeight    :: !Integer
      }
      deriving Show

--------------------------------------------------------------------------------
bufferSize :: Int
bufferSize = 4096

--------------------------------------------------------------------------------
nursery :: MonadThrow m => Nursery m a
nursery
    = do h     <- getHeader
         pos   <- getXRefPos
         xref  <- getXRef pos
         info  <- getInfo xref
         root  <- getRoot xref
         pages <- getPages xref root
         doc   <- getDocument pages
         let initState = NurseryState
                         { nurseryXRef  = xref
                         , nurseryRoot  = root
                         , nurseryInfo  = info
                         , nurseryPages = pages
                         , nurseryDoc   = doc
                         }
         rq <- respond Unit
         nurseryLoop dispatch initState rq
  where
    dispatch s RqDoc  = serveDoc s
    dispatch s RqInfo = serveInfo s

--------------------------------------------------------------------------------
serveDoc :: Monad m => NurseryState -> Nursery m (NResp, NurseryState)
serveDoc s = return (RDoc doc, s)
  where
    doc = nurseryDoc s

--------------------------------------------------------------------------------
serveInfo :: Monad m => NurseryState -> Nursery m (NResp, NurseryState)
serveInfo s = return (RInfo info, s)
  where
    info = nurseryInfo s

--------------------------------------------------------------------------------
getHeader :: MonadThrow m => Nursery m Header
getHeader
    = do bs <- driveGet 8
         case parseOnly parseHeader bs of
             Left e  -> throwM $ NurseryParsingException e
             Right h -> return h

--------------------------------------------------------------------------------
getInfo :: MonadThrow m => XRef -> Nursery m Dictionary
getInfo xref = perform action trailer
  where
    trailer = xrefTrailer xref

    action = dictKey "Info"
             . _Ref
             . act (resolveObject xref)
             . _Dict

--------------------------------------------------------------------------------
getRoot :: MonadThrow m => XRef -> Nursery m Root
getRoot xref
    = do mR <- trailer ^!? action
         case mR of
             Nothing -> throwM NurseryRootNotFound
             Just r  -> return r
  where
    trailer = xrefTrailer xref

    action
        = dictKey "Root"
          . _Ref
          . act (resolveObject xref)
          . _Dict

--------------------------------------------------------------------------------
getPages :: MonadThrow m => XRef -> Root -> Nursery m Pages
getPages xref root
    = do mP <- root ^!? action
         case mP of
             Nothing -> throwM NurseryPagesNotFound
             Just p  -> return p
  where
    action
        = dictKey "Pages"
          . _Ref
          . act (resolveObject xref)
          . _Dict

--------------------------------------------------------------------------------
getDocument :: MonadThrow m => Pages -> m Document
getDocument pages
    = case mDoc of
          Nothing -> throwM NurseryInvalidDocument
          Just d  -> return d
  where
    count = pages ^? dictKey "Count" . _Number . _Natural

    width = pages ^? dictKey "MediaBox"
                  . _Array
                  . nth 2
                  . _Number
                  . _Natural

    height = pages ^? dictKey "MediaBox"
                   . _Array
                   . nth 3
                   . _Number
                   . _Natural

    mDoc = Document <$> count <*> width <*> height

--------------------------------------------------------------------------------
resolveObject :: MonadThrow m => XRef -> Reference -> Nursery m Object
resolveObject xref ref@(idx,gen)
    = do driveTop
         driveForward
         loop ref
  where
    entries = xrefEntries xref

    loop cRef
        = case M.lookup cRef entries of
              Nothing
                  -> throwM $ NurseryUnresolvedObject idx gen
              Just e
                  -> do let offset = tableEntryOffset e
                        driveSeek offset
                        eR <- parseRepeatedly bufferSize parseIndirectObject
                        case eR of
                            Left e
                                -> throwM $ NurseryParsingException e
                            Right iObj
                                -> case indObject iObj of
                                       Ref idx gen -> loop (idx,gen)
                                       obj         -> return obj

--------------------------------------------------------------------------------
withNursery :: MonadThrow m => Client' NReq NResp m a -> Drive m a
withNursery user = nursery >>~ const user

--------------------------------------------------------------------------------
nurseryLoop :: Monad m
            => (NurseryState -> NReq -> Nursery m (NResp, NurseryState))
            -> NurseryState
            -> NReq
            -> Nursery m r
nurseryLoop k s rq
    = do (r, s') <- k s rq
         rq'     <- respond r
         nurseryLoop k s' rq'

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------
nurseryGetDocument :: Monad m => Playground m Document
nurseryGetDocument
    = do RDoc doc <- request RqDoc
         return doc

--------------------------------------------------------------------------------
nurseryGetInfo :: Monad m => Playground m Dictionary
nurseryGetInfo
    = do RInfo info <- request RqInfo
         return info
