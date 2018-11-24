{-# LANGUAGE NoImplicitPrelude, DeriveTraversable, TemplateHaskell, MultiParamTypeClasses, FlexibleContexts, TypeFamilies #-}

module AST.Unify
    ( UTerm(..), _UVar, _UTerm
    , unfreeze, freeze
    , Variable(..)
    , BindingMonad(..)
    , UnifyMonad(..)
    , unify
    ) where

import           AST
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad
import           Control.Monad.Except (MonadError(..))
import           Control.Monad.Trans.State
import           Data.Functor.Identity (Identity(..))
import           Data.IntMap (IntMap)
import           Data.Maybe (fromMaybe)
import           Data.Proxy

import           Prelude.Compat

-- Names modeled after unification-fd

data UTerm v t
    = UVar v
    | UTerm t
    deriving (Eq, Ord, Show, Functor, Foldable, Traversable)
Lens.makePrisms ''UTerm

-- | Embed a pure term as a mutable term.
unfreeze :: Children t => Node Identity t -> Node (UTerm v) t
unfreeze (Identity t) = overChildren unfreeze t & UTerm

freeze :: Children t => Node (UTerm v) t -> Maybe (Node Identity t)
freeze UVar{} = Nothing
freeze (UTerm t) = children freeze t <&> Identity

class Eq v => Variable v where
    getVarId :: v -> Int

instance Variable Int where
    getVarId = id

class Variable (Var t m) => BindingMonad t m where
    type Var t m
    lookupVar :: Var t m -> m (t (UTerm (Var t m)))
    newVar :: m (Node (UTerm (Var t m)) t)
    bindVar :: Var t m -> t (UTerm (Var t m)) -> m ()

class (BindingMonad t m, MonadError () m) => UnifyMonad t m where
    unifyBody :: t (UTerm (Var t m)) -> t (UTerm (Var t m)) -> m ()

unify :: UnifyMonad t m => Node (UTerm (Var t m)) t -> Node (UTerm (Var t m)) t -> m ()
unify x0 x1 =
    case (x0, x1, Proxy) of
    (UVar v, UTerm t, _) -> bindVar v t
    (UTerm t, UVar v, _) -> bindVar v t
    (UTerm t0, UTerm t1, p) -> unifyBody (t0 `asProxyTypeOf` p) t1
    (UVar v0, UVar v1, p)
        | v0 == v1 -> pure ()
        | otherwise ->
            unifyBody
            <$> (lookupVar v0 <&> (`asProxyTypeOf` p))
            <*> lookupVar v1
            & join
