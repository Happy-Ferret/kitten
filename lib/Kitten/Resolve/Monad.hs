{-# LANGUAGE RecordWildCards #-}

module Kitten.Resolve.Monad
  ( Env(..)
  , Resolution
  , defIndex
  , localIndex
  , withLocal
  ) where

import Control.Applicative
import Control.Monad.Trans.State
import Data.List

import Kitten.Def
import Kitten.Error
import Kitten.Resolved
import Kitten.Term (Term)

type Resolution = StateT Env (Either CompileError)

data Env = Env
  { envPrelude :: [Def Resolved]
  , envDefs :: [Def Term]
  , envScope :: [String]
  }

defIndex :: String -> Env -> Maybe Int
defIndex expected Env{..} = findExpected envPrelude
  <|> ((+ length envPrelude) <$> findExpected envDefs)
  where findExpected = findIndex $ (== expected) . defName

localIndex :: String -> Env -> Maybe Int
localIndex name = elemIndex name . envScope

withLocal :: String -> Resolution a -> Resolution a
withLocal name action = do
  modify $ \ env@Env{..} -> env { envScope = name : envScope }
  result <- action
  modify $ \ env@Env{..} -> env { envScope = tail envScope }
  return result