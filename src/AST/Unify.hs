{-# LANGUAGE NoImplicitPrelude, MultiParamTypeClasses, FlexibleContexts, LambdaCase, ScopedTypeVariables, TypeFamilies, DefaultSignatures, DataKinds #-}

module AST.Unify
    ( HasQuantifiedVar(..)
    , UniVar
    , newTerm
    , Binding(..)
    , Unify(..)
    , applyBindings, unify
    ) where

import           AST.Class.Children (Children(..))
import           AST.Class.Recursive (Recursive(..), RecursiveConstraint)
import           AST.Class.ZipMatch (ZipMatch(..), zipMatchWith_)
import           AST.Knot.Pure (Pure(..))
import           AST.Knot (Knot, Tree)
import           AST.Unify.Term
import           Control.Applicative (Alternative(..))
import           Control.Lens.Operators
import           Data.Constraint (Dict, withDict)
import           Data.Maybe (fromMaybe)
import           Data.Proxy (Proxy(..))

import           Prelude.Compat

class HasQuantifiedVar (t :: Knot -> *) where
    type family QVar t
    quantifiedVar :: QVar t -> t f

-- Names modeled after unification-fd

-- Unification variable type for a unification monad
type family UniVar (m :: * -> *) :: Knot -> *

data Binding m t = Binding
    { lookupVar :: Tree (UniVar m) t -> m (Maybe (Tree (UTerm (UniVar m)) t))
    , newVar :: m (Tree (UniVar m) t)
    , bindVar :: Tree (UniVar m) t -> Tree (UTerm (UniVar m)) t -> m ()
    }

class (Eq (Tree (UniVar m) t), ZipMatch t, HasQuantifiedVar t, Monad m) => Unify m t where
    binding :: Binding m t

    newQuantifiedVariable :: Proxy t -> m (QVar t)
    -- Default for type languages which force quantified variables to a specific type or a hole type
    default newQuantifiedVariable :: QVar t ~ () => Proxy t -> m (QVar t)
    newQuantifiedVariable _ = pure ()

    -- | A unification variable was unified with a type that contains itself,
    -- therefore the type is infinite.
    -- Break with an error if the type system doesn't allow it,
    -- or resolve the situation and generate the type represeting this loop.
    occurs :: Tree (UniVar m) t -> Tree t (UniVar m) -> m (Tree Pure t)
    default occurs :: Alternative m => Tree (UniVar m) t -> Tree t (UniVar m) -> m (Tree Pure t)
    occurs _ _ = empty

    -- | What to do when top-levels of terms being unified do not match.
    -- Usually this will throw a failure,
    -- but some AST terms could be equivalent despite not matching,
    -- like record extends with fields ordered differently,
    -- and these could still match.
    structureMismatch :: Tree t (UniVar m) -> Tree t (UniVar m) -> m ()
    default structureMismatch ::
        Alternative m => Tree t (UniVar m) -> Tree t (UniVar m) -> m ()
    structureMismatch _ _ = empty

newTerm ::
    Unify m t =>
    Tree t (UniVar m) -> m (Tree (UniVar m) t)
newTerm term =
    do
        var <- newVar binding
        var <$ bindVar binding var (UTerm term)

-- look up a variable, and return last variable pointing to result.
-- prune all variable on way to last variable
semiPruneLookup ::
    forall m t.
    Unify m t =>
    Tree (UniVar m) t ->
    m (Tree (UniVar m) t, Tree (UTerm (UniVar m)) t)
semiPruneLookup v0 =
    lookupVar binding v0
    >>=
    \case
    Nothing -> pure (v0, UVar v0)
    Just (UVar v1) ->
        do
            (v, r) <- semiPruneLookup v1
            bindVar binding v0 (UVar v)
            pure (v, r)
    Just t -> pure (v0, t)

-- TODO: implement when need / better understand motivations for -
-- unfreeze, freeze, fullPrune, occursIn, seenAs, getFreeVars, freshen, equals, equiv

applyBindings :: forall m t. Recursive (Unify m) t => Tree (UniVar m) t -> m (Tree Pure t)
applyBindings v0 =
    withDict (recursive :: Dict (RecursiveConstraint t (Unify m))) $
    semiPruneLookup v0
    >>=
    \(v1, x) ->
    let result r = r <$ bindVar binding v1 (UResolved r)
    in
    case x of
    UResolving t -> occurs v1 t
    UResolved t -> pure t
    UVar{} ->
        newQuantifiedVariable (Proxy :: Proxy t) <&> quantifiedVar <&> Pure
        >>= result
    UTerm t ->
        case leafExpr of
        Just f -> f t & Pure & pure
        Nothing ->
            do
                bindVar binding v1 (UResolving t)
                children (Proxy :: Proxy (Recursive (Unify m))) applyBindings t
            <&> Pure
            >>= result

-- Note on usage of `semiPruneLookup`:
--   Variables are pruned to point to other variables rather than terms,
--   yielding comparison of (sometimes equal) variables,
--   rather than recursively unifying the terms that they would prune to.
unify ::
    forall m t.
    Recursive (Unify m) t =>
    Tree (UniVar m) t -> Tree (UniVar m) t -> m ()
unify x0 y0 =
    withDict (recursive :: Dict (RecursiveConstraint t (Unify m))) $
    let unifyTerms x y =
            zipMatchWith_ (Proxy :: Proxy (Recursive (Unify m))) unify x y
            & fromMaybe (structureMismatch x y)
    in
    if x0 == y0
        then pure ()
        else go x0 y0 (\x1 xt -> go y0 x1 (const (unifyTerms xt)))
    where
        go var other onTerm =
            semiPruneLookup var
            >>=
            \case
            (v1, _) | v1 == other -> pure ()
            (_, UVar v1) -> bindVar binding v1 (UVar other)
            (v1, UTerm t) -> onTerm v1 t
            (_, _) -> error "This shouldn't happen in unification stage"
