{-# LANGUAGE NoImplicitPrelude, DataKinds, TypeFamilies, RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, DefaultSignatures, FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds, TypeOperators, ScopedTypeVariables, UndecidableInstances #-}

module AST.Unify.Constraints
    ( TypeConstraints(..)
    , HasTypeConstraints(..)
    , TypeConstraintsAre
    , MonadScopeConstraints(..)
    ) where

import Algebra.Lattice (JoinSemiLattice(..))
import Algebra.PartialOrd (PartialOrd(..))
import AST
import AST.Class.Combinators (And)
import Data.Proxy (Proxy(..))

import Prelude.Compat

class (PartialOrd c, JoinSemiLattice c) => TypeConstraints c where
    -- | Remove scope constraints
    generalizeConstraints :: c -> c

class
    TypeConstraints (TypeConstraintsOf ast) =>
    HasTypeConstraints (ast :: Knot -> *) where

    type TypeConstraintsOf ast

    verifyConstraints ::
        (Applicative m, ChildrenWithConstraint ast constraint) =>
        Proxy constraint ->
        TypeConstraintsOf ast ->
        (TypeConstraintsOf ast -> m ()) ->
        (forall child. constraint child => TypeConstraintsOf child -> Tree p child -> m (Tree q child)) ->
        Tree ast p -> m (Tree ast q)
    default verifyConstraints ::
        forall m constraint p q.
        ( ChildrenWithConstraint ast (constraint `And` TypeConstraintsAre (TypeConstraintsOf ast))
        , Applicative m
        ) =>
        Proxy constraint ->
        TypeConstraintsOf ast ->
        (TypeConstraintsOf ast -> m ()) ->
        (forall child. constraint child => TypeConstraintsOf child -> Tree p child -> m (Tree q child)) ->
        Tree ast p -> m (Tree ast q)
    verifyConstraints _ constraints _ update =
        children (Proxy :: Proxy (constraint `And` TypeConstraintsAre (TypeConstraintsOf ast)))
        (update constraints)

class TypeConstraintsOf ast ~ constraints => TypeConstraintsAre constraints ast
instance TypeConstraintsOf ast ~ constraints => TypeConstraintsAre constraints ast

class Monad m => MonadScopeConstraints c m where
    scopeConstraints :: m c
