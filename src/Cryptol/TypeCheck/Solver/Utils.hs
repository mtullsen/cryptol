-- |
-- Module      :  Cryptol.TypeCheck.Solver.Utils
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

module Cryptol.TypeCheck.Solver.Utils where

import Cryptol.TypeCheck.AST hiding (tMul)
import Cryptol.TypeCheck.SimpType(tAdd,tMul)
import Control.Monad(mplus,guard)
import Data.Maybe(listToMaybe)



-- | All ways to split a type in the form: @a + t1@, where @a@ is a variable.
splitVarSummands :: Type -> [(TVar,Type)]
splitVarSummands ty0 = [ (x,t1) | (x,t1) <- go ty0, tNum (0::Int) /= t1 ]
  where
  go ty = case ty of
            TVar x      -> return (x, tNum (0::Int))
            TRec {}     -> []
            TNominal {}  -> []
            TUser _ _ t -> go t
            TCon (TF TCAdd) [t1,t2] ->
              do (a,yes) <- go t1
                 return (a, tAdd yes t2)
              `mplus`
              do (a,yes) <- go t2
                 return (a, tAdd t1 yes)
            TCon _ _    -> [] -- XXX: we could do some distributivity etc


-- | Check if we can express a type in the form: @a + t1@.
splitVarSummand :: TVar -> Type -> Maybe Type
splitVarSummand a ty = listToMaybe [ t | (x,t) <- splitVarSummands ty, x == a ]

{- | Check if we can express a type in the form: @k + t1@,
where @k@ is a constant > 0.
This assumes that the type has been simplified already,
so that constants are floated to the left. -}
splitConstSummand :: Type -> Maybe (Integer, Type)
splitConstSummand ty =
  case ty of
    TVar {}     -> Nothing
    TRec {}     -> Nothing
    TNominal {} -> Nothing
    TUser _ _ t -> splitConstSummand t
    TCon (TF TCAdd) [t1,t2] ->
      do (k,t1') <- splitConstSummand t1
         case t1' of
           TCon (TC (TCNum 0)) [] -> return (k, t2)
           _                      -> return (k, tAdd t1' t2)
    TCon (TC (TCNum k)) [] -> guard (k > 0) >> return (k, tNum (0::Int))
    TCon {}     -> Nothing

{- | Check if we can express a type in the form: @k * t1@,
where @k@ is a constant > 1.
This assumes that the type has been simplified already,
so that constants are floated to the left. -}
splitConstFactor :: Type -> Maybe (Integer, Type)
splitConstFactor ty =
  case ty of
    TVar {}     -> Nothing
    TRec {}     -> Nothing
    TNominal {} -> Nothing
    TUser _ _ t -> splitConstFactor t
    TCon (TF TCMul) [t1,t2] ->
      do (k,t1') <- splitConstFactor t1
         return (k, tMul t1' t2)
    TCon (TC (TCNum k)) [] -> guard (k > 1) >> return (k, tNum (1::Int))
    TCon {}     -> Nothing




