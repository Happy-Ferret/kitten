{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Kitten.Compile
  ( compile
  ) where

import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.Either
import Data.HashMap.Strict (HashMap)
import Data.List
import Data.Monoid
import Data.Set (Set)
import Data.Text (Text)
import System.Directory
import System.FilePath
import System.IO
import System.IO.Error
import Text.Parsec.Error
import Text.Parsec.Pos

import qualified Data.HashMap.Strict as H
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Vector as V

import Kitten.Config
import Kitten.Definition
import Kitten.Error
import Kitten.Fragment
import Kitten.IR
import Kitten.Import
import Kitten.Infer
import Kitten.Kind
import Kitten.Location
import Kitten.Name
import Kitten.Operator
import Kitten.Optimize
import Kitten.Parse
import Kitten.Program
import Kitten.Resolve
import Kitten.Scope
import Kitten.Term
import Kitten.Tokenize
import Kitten.Type
import Kitten.TypeDefinition
import Kitten.Util.Either
import Kitten.Util.Monad
import Kitten.Util.Text (ToText(..))

import qualified Kitten.IdMap as Id
import qualified Kitten.Util.Text as T

liftParseError :: Either ParseError a -> Either [ErrorGroup] a
liftParseError = mapLeft ((:[]) . parseError)

parseSource
  :: Int
  -> String
  -> Text
  -> Either [ErrorGroup] (Fragment ParsedTerm)
parseSource line name source = do
  tokenized <- liftParseError $ tokenize line name source
  mapLeft (:[]) $ parse name tokenized

compile
  :: Config
  -> Program
  -> IO (Either [ErrorGroup] (Program, Int, Type 'Scalar))
compile config@Config{..} program
  = liftM (mapLeft sort) . runEitherT $ do

  parsed <- addPreludeImport <$> hoistEither
    (parseSource configFirstLine configName configSource)

  substituted <- hoistEither
    =<< lift (substituteImports configLibraryDirectories parsed)

  -- Applicative rewriting must take place after imports have been
  -- substituted, so that all operator declarations are in scope.
  (postfix, program') <- hoistEither . mapLeft (:[]) $ rewriteInfix program substituted
  resolved <- hoistEither $ resolve postfix program'

  when configDumpResolved . lift $ hPrint stderr resolved

  let scoped = scope resolved
  when configDumpScoped . lift $ hPrint stderr scoped

  let (mTypedAndType, program'') = runK program' config $ typeFragment scoped
  (typed, type_) <- hoistEither mTypedAndType

  when configDumpTyped . lift $ hPrint stderr typed

  let
    (mErrors, program''') = ir typed
      program''
        { programAbbrevs = programAbbrevs program'' <> fragmentAbbrevs typed
        , programTypes = programTypes program'' <> fragmentTypes typed
        }
      config
  void $ hoistEither mErrors

  let program'''' = optimize configOptimizations program'''

  return
    ( program''''
    , maybe 0 V.length $ Id.lookup entryId (programBlocks program)
    , type_
    )
  where
  addPreludeImport fragment
    | configImplicitPrelude = fragment
      { fragmentImports = Import
        { importName = "Prelude"
        , importLocation = Location
          { locationStart = initialPos "Prelude"
          , locationIndent = 0
          }
        } : fragmentImports fragment
      }
    | otherwise = fragment

locateImport
  :: [FilePath]
  -> Name
  -> IO [FilePath]
locateImport libraryDirectories importName = do
  currentDirectory <- getCurrentDirectory

  let
    searchDirectories :: [FilePath]
    searchDirectories
      = "."
      : ("." </> "lib")
      : libraryDirectories
      ++ [currentDirectory, currentDirectory </> "lib"]

  fmap nub $ filterM doesFileExist
    =<< mapMaybeM canonicalImport searchDirectories

  where
  canonicalImport :: FilePath -> IO (Maybe FilePath)
  canonicalImport path = catchIOError
    (Just <$> canonicalizePath (path </> show importName <.> "ktn"))
    $ \e -> if isDoesNotExistError e then return Nothing else ioError e

substituteImports
  :: [FilePath]
  -> Fragment ParsedTerm
  -> IO (Either [ErrorGroup] (Fragment ParsedTerm))
substituteImports libraryDirectories fragment = runEitherT $ do
  (,,,)
    substitutedAbbrevs
    substitutedDefs
    substitutedOperators
    substitutedTypes <- go
    (fragmentImports fragment)
    S.empty
    ( fragmentAbbrevs fragment
    , H.toList (fragmentDefs fragment)
    , fragmentOperators fragment
    , fragmentTypes fragment
    )
  return fragment
    { fragmentAbbrevs = substitutedAbbrevs
    , fragmentDefs = H.fromList substitutedDefs
    , fragmentOperators = substitutedOperators
    , fragmentTypes = substitutedTypes
    }
  where
  go
    :: [Import]
    -> Set Name
    -> ( HashMap (Qualifier, Text) Qualifier
       , [(Name, Def ParsedTerm)]
       , [Operator]
       , HashMap Name TypeDef
       )
    -> EitherT [ErrorGroup] IO
      ( HashMap (Qualifier, Text) Qualifier
      , [(Name, Def ParsedTerm)]
      , [Operator]
      , HashMap Name TypeDef
      )
  go [] _ acc = return acc
  go (currentModule : remainingModules) seenModules
    acc@(abbrevs, defs, operators, types) = let
    name = importName currentModule
    location = importLocation currentModule
    in if name `S.member` seenModules
      then go remainingModules seenModules acc
      else do
        possible <- lift $ locateImport libraryDirectories name
        case possible of
          [filename] -> do
            source <- lift $ T.readFileUtf8 filename
            parsed <- hoistEither $ parseSource 1 filename source
            go
              (fragmentImports parsed ++ remainingModules)
              (S.insert name seenModules)
              ( fragmentAbbrevs parsed <> abbrevs
              , H.toList (fragmentDefs parsed) ++ defs
              , fragmentOperators parsed ++ operators
              , fragmentTypes parsed <> types
              )
          [] -> err location $ T.concat
            ["missing import '", toText name, "'"]
          _ -> err location $ T.concat
            ["ambiguous import '", toText name, "'"]
  err loc = left . (:[]) . oneError . CompileError loc Error
