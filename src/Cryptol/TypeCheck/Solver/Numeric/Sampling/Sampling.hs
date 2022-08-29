{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant pure" #-}

module Cryptol.TypeCheck.Solver.Numeric.Sampling.Sampling where

import Control.Monad (foldM_, void)
import Control.Monad.Except (MonadError (throwError))
import Control.Monad.State as State
  ( MonadState (get, put),
    MonadTrans (lift),
    StateT,
    evalStateT,
    gets,
    modify,
  )
import Cryptol.TypeCheck.Solver.InfNat (Nat' (..))
import Cryptol.TypeCheck.Solver.Numeric.Sampling.Base
  ( SamplingError (SamplingError),
    SamplingM,
    debug,
    debug',
    integer_max,
  )
import Cryptol.TypeCheck.Solver.Numeric.Sampling.Exp (Exp (..), Var (..))
import qualified Cryptol.TypeCheck.Solver.Numeric.Sampling.Exp as Exp
import Cryptol.TypeCheck.Solver.Numeric.Sampling.SolvedConstraints (SolvedConstraints)
import qualified Cryptol.TypeCheck.Solver.Numeric.Sampling.SolvedConstraints as SolCons
import qualified Data.List as List
import Data.Vector (Vector)
import qualified Data.Vector as V
import System.Random.TF.Gen (TFGen)
import System.Random.TF.Instances (Random (randomR))

liftR :: (TFGen -> (a, TFGen)) -> SamplingM a
liftR k = do
  (a, g) <- lift $ gets k
  lift $ put g
  pure a

type WeightedRange = [WeightedRangeItem]

data WeightedRangeItem = WeightedRangeItem
  { weightWRI :: Integer,
    valueWRI :: Integer
  }

totalWeight :: WeightedRange -> Integer
totalWeight = sum . fmap weightWRI

weightedRangeLinSkewSmall :: Integer -> WeightedRange
weightedRangeLinSkewSmall max =
  ( \n ->
      WeightedRangeItem
        { weightWRI = max - n + 1,
          valueWRI = n
        }
  )
    <$> [0 .. max]

-- OLD
-- -- samples an integer with a linear skew towards smaller values
-- sampleLinSkewSmall :: (Integer, Integer) -> SamplingM Integer
-- sampleLinSkewSmall (lo, hi)
--   | hi < lo = error "sampleLinSkewSmall of empty range"
--   | otherwise = do
--     let n = hi - lo
--     let rng = weightedRangeLinSkewSmall n
--     i <- liftR $ randomR (0, weightWRI $ last rng)
--     Just (n', _) <- pure $ List.find (\(_, i') -> i <= i') rng
--     pure $ lo + n'

maxInteger :: Integer
maxInteger = 128

weightInf :: Integer
weightInf = 10 -- TODO

-- statically compute for efficiency
weightedRangeQuadSkewSmallUpToMaxInteger :: WeightedRange
weightedRangeQuadSkewSmallUpToMaxInteger =
  ( \n ->
      WeightedRangeItem
        { weightWRI = (maxInteger - n + 1) ^ 2,
          valueWRI = n
        }
  )
    <$> [0 .. maxInteger]

-- statically compute for efficiency
totalWeight_weightedRangeQuadSkewSmallUpToMaxInteger :: Integer
totalWeight_weightedRangeQuadSkewSmallUpToMaxInteger = totalWeight weightedRangeQuadSkewSmallUpToMaxInteger

-- OLD
-- -- [(n, i)]
-- weightedRangeQuadSkewSmallUpToMaxInteger :: WeightedRange
-- weightedRangeQuadSkewSmallUpToMaxInteger = f 0 0
--   where
--     f :: Integer -> Integer -> [(Integer, Integer)]
--     f n i
--       | n > maxInteger = []
--       | otherwise = (maxInteger - n, i) : f (n + 1) (i + ((n + 1) ^ (2 :: Integer)))

-- OLD
-- -- samples an integer with an quadratic skew towards smaller values
-- sampleQuadSkewSmallUpToMaxInteger :: SamplingM Integer
-- sampleQuadSkewSmallUpToMaxInteger = do
--   let rng = weightedRangeQuadSkewSmallUpToMaxInteger
--   i <- liftR $ randomR (0, snd $ last rng)
--   Just (n, _) <- pure $ List.find (\(_, i') -> i < i') rng
--   pure n

-- find the first `a` that satisfies `f a b = Nothing`, where `b` is accumulated
-- over the `a'` such that `f a' b = Just b'`
foldFind :: (a -> b -> Maybe b) -> b -> [a] -> Maybe a
foldFind _ _ [] = Nothing
foldFind f b (a : as) = case f a b of
  Just b' -> foldFind f b' as
  Nothing -> Just a

sampleWeightedRange :: WeightedRange -> Integer -> SamplingM Integer
sampleWeightedRange wr totalWeight_ = do
  i <- liftR $ randomR (0, totalWeight_)
  let Just wri =
        foldFind
          ( \wri accumWeight ->
              let accumWeight' = weightWRI wri + accumWeight
               in if accumWeight' >= i
                    then Nothing -- found sample
                    else Just accumWeight'
          )
          (0 :: Integer)
          wr
  pure $ valueWRI wri

data Range
  = -- upper-bounded by expressions
    UpperBounded [Exp Nat']
  | -- equal to an expression, and upper-bounded by expressions
    EqualAndUpperBounded (Exp Nat') [Exp Nat']
  | -- already sampled
    Fixed Nat'

instance Show Range where
  show = \case
    UpperBounded exps -> "UpperBounded " ++ show exps
    EqualAndUpperBounded exp exps -> "EqualAndUpperBounded (" ++ show exp ++ ")" ++ " " ++ show exps
    Fixed na -> "Fixed (" ++ show na ++ ")"

{-
Sample solved constraints
1. Collect upper bounds on each var
2. Sampling procedure:
  1. Sample each var in order, statefully keeping track of samplings so far
  2. To sample a var: If it's `Range` is `EqualAndUpperBounded` then the variable's value is
    equal to the sampling of the one expression, so sample that expression.

    -- TODO: talk about how EqualAndUpperBounded can be upperbounded too

    If it's `Range` is `UpperBounded` then sample each upper-bounding expression
    then sample a value (TODO: how to weightWRI choice) between `0` and the minimum
    of the sampled upper-bounding values. Then update the variable's `Range` to
    be `EqualAndUpperBounded` of the value just sampled for it.
-}

-- TODO: make use of `fin` type constraint
sample :: SolvedConstraints Nat' -> SamplingM (Vector Integer)
sample solcons = do
  let vars = V.generate (SolCons.nVars solcons) Var

  debug' 1 $ "nVars = " ++ show (SolCons.nVars solcons)

  let solsys = SolCons.solsys solcons

  let initRanges = V.replicate (SolCons.nVars solcons) (UpperBounded [Exp.fromConstant (SolCons.nVars solcons) Inf])

  vals <- flip evalStateT initRanges do
    let getRange :: Var -> StateT (Vector Range) SamplingM Range
        getRange i = gets (V.! unVar i)

    let setEqual :: Var -> Exp Nat' -> StateT (Vector Range) SamplingM ()
        -- setEqual i e = (V.// [(unVar i, EqualAndUpperBounded e [])])
        setEqual i e =
          getRange i >>= \case
            UpperBounded bs -> modify (V.// [(unVar i, EqualAndUpperBounded e bs)])
            EqualAndUpperBounded _ _ -> throwError $ SamplingError "sample" "A variable was solved for more than once, which should never result from Gaussian elimination."
            Fixed _ -> throwError $ SamplingError "sample" "Attempted to `setEqual` a `Fixed` range variable"

    let addUpperBounds :: Var -> [Exp Nat'] -> StateT (Vector Range) SamplingM ()
        addUpperBounds i bs' =
          getRange i >>= \case
            UpperBounded bs -> modify (V.// [(unVar i, UpperBounded (bs <> bs'))])
            -- FIX: if x = y and x is bounded by 3, then this will ignore that
            -- bound, and so y can be assigned to 10 and then x will also be 10
            EqualAndUpperBounded e bs -> modify (V.// [(unVar i, EqualAndUpperBounded e (bs <> bs'))])
            -- can't upper-bound something that's already fixed...
            -- TODO: this shouldn't happen!
            -- TODO: should this be an error?
            Fixed _ -> pure ()

    let setFixed :: Var -> Nat' -> StateT (Vector Range) SamplingM ()
        setFixed i n' = modify (V.// [(unVar i, Fixed n')])

        divNat' :: Nat' -> Nat' -> Nat'
        Inf `divNat'` Inf = Nat 1
        Inf `divNat'` Nat n | n > 0 = Inf
        Inf `divNat'` Nat n | n < 0 = error "Attempted to divide Inf by a negative."
        Inf `divNat'` Nat n = error "Attempted to divide Inf by zero."
        Nat n `divNat'` Inf = Nat 0
        Nat n1 `divNat'` Nat n2 = Nat (n1 `div` n2)

    -- accumulate ranges
    V.mapM_
      ( \(i, mb_e) -> do
          case mb_e of
            Just e@(Exp as c) -> do
              -- We need to account for the upper bounds on `xi` when
              -- determining the upper bounds on the positive terms in `e`.
              bs <-
                getRange i >>= \case
                  UpperBounded bs -> pure bs
                  EqualAndUpperBounded _ _ -> throwError $ SamplingError "sample" "A variable has a `EqualAndUpperBounded` range before handling its equation during the upper-bounding pass."
                  Fixed _ -> throwError $ SamplingError "sample" "A variable has a `Fixed` range during the upper-bounding pass."
              --
              -- positive-coefficient and negative-coefficient variables
              let iPtvs = Var <$> V.findIndices (0 <) as
                  iNegs = Var <$> V.findIndices (0 >) as
              --
              -- Suppose we have
              --
              --   x = 2y + 3z + (-4)u + (-5)v <= 10
              --
              -- First, upper-bound all of the positive-coefficient variables
              -- like so:
              --
              --    y <= 10/2
              --    z <= (10 - 2y)/3
              --
              -- Second, upper-bound all of the negative-coefficient variables
              -- like so:
              --
              --    u <= (2y + 3z)/4
              --    v <= (2y + 3z - 4u)/5
              --
              -- upper-bound ptv-coeff vars
              --
              lift $ debug' 2 $ "as = " ++ show (V.toList as)
              foldM_
                ( \bs i' -> do
                    let ai' = e Exp.! i'
                    lift $ debug' 2 $ "i' = " ++ show i
                    lift $ debug' 2 $ "ai' = " ++ show ai'
                    lift $ debug' 2 $ "bs = " ++ show bs
                    let bs' = fmap (`divNat'` ai') <$> bs
                    lift $ debug' 2 $ "upper-bounding " ++ show i' ++ " by " ++ show bs'
                    addUpperBounds i' bs'
                    let bs'' = fmap (Exp.// [(i', 0)]) bs
                    pure bs''
                )
                bs
                iPtvs
              -- upper-bound neg-coeff vars
              foldM_
                ( \e' i' -> do
                    let ai' = e Exp.! i'
                    e' <- pure $ (Exp.// [(i', 0)]) . fmap (`divNat'` abs ai') $ e'
                    lift $ debug' 2 $ "upper-bounding " ++ show i' ++ " by " ++ show e'
                    addUpperBounds i' [e']
                    pure e'
                )
                e
                iNegs
              -- add equality
              setEqual i e
            Nothing -> pure ()
      )
      (V.generate (SolCons.nVars solcons) Var `V.zip` solsys)

    void do
      rs <- get
      lift $ debug' 1 $ "rs =\n" ++ unlines (("  " ++) . show <$> V.toList rs)

    -- sample all the vars

    -- TMP
    -- let randomWeightedR :: (Integer -> Integer) -> (Integer, Integer) -> TFGen -> (Integer, TFGen)
    --     randomWeightedR _ (lo, hi) g | hi - lo <= 0 = error "randomWeightedR of empty range"
    --     randomWeightedR weightWRI (lo, hi) g =
    --       let xs = [lo .. hi]
    --           weights = weightWRI <$> [lo .. hi]
    --           (y, g) = randomR (0, sum weights) g
    --           findSample _ [] = error "randomWeightedR: impossible"
    --           findSample acc ((x, w) : xs_ws)
    --             | y >= acc = x
    --             | null xs_ws = x
    --             | otherwise = findSample (acc + w) xs_ws
    --           x = findSample 0 (xs `zip` weights)
    --        in (x, g)

    let sampleNat' :: Nat' -> StateT (Vector Range) SamplingM Nat'
        sampleNat' Inf = Nat <$> lift (sampleWeightedRange weightedRangeQuadSkewSmallUpToMaxInteger totalWeight_weightedRangeQuadSkewSmallUpToMaxInteger)
        sampleNat' (Nat n) = Nat <$> lift (let wr = weightedRangeLinSkewSmall n in sampleWeightedRange wr (totalWeight wr))
        
        minimumUpperBound :: [Exp Nat'] -> StateT (Vector Range) SamplingM Nat'
        minimumUpperBound [] = pure Inf
        minimumUpperBound bs = minimum <$> (sampleExp Inf `traverse` bs)

        sampleVar :: Var -> StateT (Vector Range) SamplingM Nat'
        sampleVar i = do
          lift . debug' 1 $ "sampling var: " ++ show i
          range <- getRange i
          lift . debug' 1 $ "       range: " ++ show range
          -- sample from `Range`
          val <- case range of
            UpperBounded bs -> do
              -- upper bound
              n <- minimumUpperBound bs
              -- TODO: weightWRI choices
              sampleNat' n
            EqualAndUpperBounded e bs -> do
              -- upper bound
              n <- minimumUpperBound bs
              -- TODO: weightWRI choices
              sampleExp n e
            Fixed n -> pure n
          -- set xi := val
          setFixed i val
          lift . debug' 1 $ show i ++ " ==> " ++ show val
          --
          pure val

        -- sample an expression that is upper bounded by a constant
        sampleExp :: Nat' -> Exp Nat' -> StateT (Vector Range) SamplingM Nat'
        sampleExp n e@(Exp as c) = do
          lift . debug' 1 $ "sampling exp: " ++ show (Exp as c)
          -- only sampleuates terms that have non-0 coeff
          n <-
            (c +)
              . V.sum
              <$> ( \(i, a) ->
                      if a /= 0
                        then (a *) <$> sampleVar i
                        else pure 0
                  )
              `traverse` (vars `V.zip` as)
          lift . debug' 1 $ show e ++ " ==> " ++ show n
          pure n

    -- In theory, this should work with dependencies correctly, since if
    -- sampling something depends on sampling something else first, then if will
    -- trigger a statefull sampling which does that.
    vals <- sampleVar `traverse` vars
    pure vals
  -- sample all the vars
  -- vals <- evalStateT (sampleVar `traverse` vars) rs

  -- cast to Integer
  let fromNat' :: Nat' -> Integer
      fromNat' Inf = integer_max
      fromNat' (Nat n) = n
  pure $ fromNat' <$> vals
