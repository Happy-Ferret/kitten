{-# LANGUAGE OverloadedStrings #-}

module Test.Term where

import Control.Arrow
import Control.Monad
import Data.HashMap.Strict (HashMap)
import Data.Monoid
import Data.Text (Text)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec

import qualified Data.HashMap.Strict as H
import qualified Data.Vector as V

import Kitten.Error
import Kitten.Location
import Kitten.Parse
import Kitten.Tokenize
import Kitten.Types
import Kitten.Util.Either
import Kitten.Util.Monad
import Test.Util

spec :: Spec
spec = do
  describe "empty program"
    $ testTerm "" mempty

  describe "terms" $ do
    testTerm "1 2 3"
      mempty { fragmentTerms = V.fromList [pushi 1, pushi 2, pushi 3] }
    testTerm "dup swap drop vector cat function compose"
      $ mempty { fragmentTerms = V.fromList
        [ word "dup"
        , word "swap"
        , word "drop"
        , word "vector"
        , word "cat"
        , word "function"
        , word "compose"
        ] }

  describe "function" $ do

    testTerm
      "{}"
      $ mempty { fragmentTerms = V.fromList
        [push $ quotation []] }

    testTerm
      "{3}"
      $ mempty { fragmentTerms = V.fromList
        [push $ quotation [pushi 3]] }

    testTerm
      "{ 1 (+) }"
      $ mempty { fragmentTerms = V.fromList
        [push $ quotation [pushi 1, word "+"]] }

  describe "lambda" $ do

    testTerm
      "->x; x x (*)"
      $ mempty { fragmentTerms = V.fromList
        [ lambda "x"
          [ word "x"
          , word "x"
          , word "*"]] }

    testTerm
      "->x; ->y; x y (*)"
      $ mempty { fragmentTerms = V.fromList
        [ lambda "x"
          [ lambda "y"
            [ word "x"
            , word "y"
            , word "*"]]] }

    testTerm
      "{ ->x; ->y; x y (*) }"
      $ mempty { fragmentTerms = V.fromList
        [ push $ quotation
          [ lambda "x"
            [ lambda "y"
              [ word "x"
              , word "y"
              , word "*"]]]] }

    testTerm
      ": ->x; ->y; x y (*)"
      $ mempty { fragmentTerms = V.fromList
        [ push $ quotation
          [ lambda "x"
            [ lambda "y"
              [ word "x"
              , word "y"
              , word "*"]]]] }

  describe "layout" $ do

    testTerm
      ": sameLine\n\
      \  nextLine\n\
      \  anotherLine\n"
      $ mempty { fragmentTerms = V.fromList
        [ push $ quotation
          [ word "sameLine"
          , word "nextLine"
          , word "anotherLine"]] }

    testTerm
      "{ : sameLine\n\
      \    nextLine\n\
      \    anotherLine }\n"
      $ mempty { fragmentTerms = V.fromList
        [ push $ quotation
          [ push $ quotation
            [ word "sameLine"
            , word "nextLine"
            , word "anotherLine"]]] }

    testTerm "{ one : two three }"
      $ mempty { fragmentTerms = V.fromList
        [ push $ quotation
          [ word "one"
          , push $ quotation
            [ word "two"
            , word "three"]]] }

    testTerm ": {one} {two}"
      $ mempty { fragmentTerms = V.fromList
        [ push $ quotation
          [ push $ quotation [word "one"]
          , push $ quotation [word "two"]]] }

    testTerm
      "\\option (0 some):\n\
      \  drop // This comment is necessary.\n\
      \else:\n\
      \  noop\n"
      $ mempty { fragmentTerms = V.fromList
        [ compose [compose [pushi 0, call "some"]
        , push $ quotation [call "drop"]
        , push $ quotation [call "noop"]
        , word "option_else"]] }

    testTermFailure ":"

    testTermFailure
      "  :\n\
      \3\n"

    testTermFailure
      ":\n\
      \3\n"

    testTerm
      ": :\n\
      \  3\n"
      $ mempty { fragmentTerms = V.fromList
        [push $ quotation [push $ quotation [pushi 3]]] }

  describe "definition" $ do

    testTerm
      "def pi (-> Float): 3"
      $ mempty { fragmentDefs = defList
        [def "pi" $ compose [pushi 3]] }

    testTerm
      "def inc (int -> int) {\n\
      \  1 (+)\n\
      \}\n"
      $ mempty { fragmentDefs = defList
        [def "inc" $ compose [pushi 1, word "+"]] }

    testTerm
      "def inc (int -> int):\n\
      \  1 (+)\n\
      \\n\
      \def dec (int -> int):\n\
      \  1 (-)\n\
      \\n"
      $ mempty { fragmentDefs = defList
        [ def "inc" $ compose [pushi 1, word "+"]
        , def "dec" $ compose [pushi 1, word "-"]] }

  describe "type" $ testTerm
    "def curriedAdd (int -> int -> int) {\n\
    \  ->x;\n\
    \  { ->y; x y (+) }\n\
    \}"
    $ mempty { fragmentDefs = defList
      [ defWithAnno "curriedAdd"
        (AnFunction
          (V.fromList [AnVar "int"])
          (V.fromList
            [AnFunction
              (V.fromList [AnVar "int"])
              (V.fromList [AnVar "int"])]))
        $ compose
          [ lambda "x"
            [ push $ quotation
              [ lambda "y"
                [word "x", word "y", word "+"]]]]] }

defList :: [Def a] -> HashMap Text (Def a)
defList = H.fromList . map (defName &&& id)

testTerm :: Text -> Fragment ParsedTerm -> Spec
testTerm source expected = it (show source)
  $ case parsed source of
    Left message -> assertFailure $ show message
    Right actual
      | expected == actual -> noop
      | otherwise -> expectedButGot
        (show expected) (show actual)

testTermFailure :: Text -> Spec
testTermFailure source = it ("should fail: " ++ show source)
  $ case parsed source of
    Left _ -> noop
    Right actual -> assertFailure $ show actual

parsed :: Text -> Either ErrorGroup (Fragment ParsedTerm)
parsed = mapLeft parseError . tokenize 1 "test"
  >=> parse "test" >=> rewriteInfix

def :: Text -> a -> Def a
def name term = Def
  { defAnno = TestAnno
  , defFixity = Postfix
  , defLocation = TestLocation
  , defName = name
  , defTerm = mono term
  }

defWithAnno :: Text -> AnType -> a -> Def a
defWithAnno name anno term = (def name term)
  { defAnno = Anno anno TestLocation }

call :: Text -> ParsedTerm
call name = TrCall Postfix name TestLocation

compose :: [ParsedTerm] -> ParsedTerm
compose terms = TrCompose StackAny (V.fromList terms) TestLocation

quotation :: [ParsedTerm] -> ParsedValue
quotation terms = TrQuotation
  (TrCompose StackAny (V.fromList terms) TestLocation) TestLocation

int :: Int -> ParsedValue
int value = TrInt value TestLocation

pushi :: Int -> ParsedTerm
pushi value = push $ int value

lambda :: Text -> [ParsedTerm] -> ParsedTerm
lambda name terms
  = TrLambda name (compose terms) TestLocation

push :: ParsedValue -> ParsedTerm
push value = TrPush value TestLocation

word :: Text -> ParsedTerm
word value = TrCall Postfix value TestLocation
