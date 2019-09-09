-- | Type schemes

{-# LANGUAGE TemplateHaskell, FlexibleContexts, DefaultSignatures #-}
{-# LANGUAGE FlexibleInstances, UndecidableInstances, GADTs #-}

module AST.Term.Scheme
    ( Scheme(..), sForAlls, sTyp, KWitness(..)
    , QVars(..), _QVars
    , HasScheme(..), loadScheme, saveScheme
    , MonadInstantiate(..), inferType

    , QVarInstances(..), _QVarInstances
    , makeQVarInstances
    ) where

import           AST
import           AST.Class.Has (HasChild(..))
import           AST.Class.Recursive
import           AST.Combinator.ANode (ANode)
import           AST.Combinator.Flip (Flip(..))
import           AST.Infer
import           AST.TH.Internal.Instances (makeCommonInstances)
import           AST.Unify
import           AST.Unify.Lookup (semiPruneLookup)
import           AST.Unify.New (newTerm)
import           AST.Unify.Generalize
import           AST.Unify.QuantifiedVar (HasQuantifiedVar(..), MonadQuantify(..), OrdQVar)
import           AST.Unify.Term (UTerm(..), uBody)
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.State (StateT(..))
import           Data.Constraint
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Proxy (Proxy(..))
import           GHC.Generics (Generic)
import           Text.PrettyPrint ((<+>))
import qualified Text.PrettyPrint as Pretty
import           Text.PrettyPrint.HughesPJClass (Pretty(..), maybeParens)

import           Prelude.Compat

-- | A type scheme representing a polymorphic type.
data Scheme varTypes typ k = Scheme
    { _sForAlls :: Tree varTypes QVars
    , _sTyp :: k # typ
    } deriving Generic

newtype QVars typ = QVars
    (Map (QVar (GetKnot typ)) (TypeConstraintsOf (GetKnot typ)))
    deriving stock Generic

newtype QVarInstances k typ = QVarInstances (Map (QVar (GetKnot typ)) (k typ))
    deriving stock Generic

Lens.makeLenses ''Scheme
Lens.makePrisms ''QVars
Lens.makePrisms ''QVarInstances
makeCommonInstances [''Scheme, ''QVars, ''QVarInstances]
makeKTraversableApplyAndBases ''Scheme

instance RNodes t => RNodes (Scheme v t)
instance (c (Scheme v t), Recursively c t) => Recursively c (Scheme v t)
instance (KTraversable (Scheme v t), RTraversable t) => RTraversable (Scheme v t)
instance (RTraversable t, RTraversableInferOf t) => RTraversableInferOf (Scheme v t)

instance
    (RNodes t, c t, Recursive c, ITermVarsConstraint c t) =>
    ITermVarsConstraint c (Scheme v t)

instance
    ( Ord (QVar (GetKnot typ))
    , Semigroup (TypeConstraintsOf (GetKnot typ))
    ) =>
    Semigroup (QVars typ) where
    QVars m <> QVars n = QVars (Map.unionWith (<>) m n)

instance
    ( Ord (QVar (GetKnot typ))
    , Semigroup (TypeConstraintsOf (GetKnot typ))
    ) =>
    Monoid (QVars typ) where
    mempty = QVars Map.empty

instance
    (Pretty (Tree varTypes QVars), Pretty (k # typ)) =>
    Pretty (Scheme varTypes typ k) where

    pPrintPrec lvl p (Scheme forAlls typ) =
        pPrintPrec lvl 0 forAlls <+>
        pPrintPrec lvl 0 typ
        & maybeParens (p > 0)

instance
    (Pretty (TypeConstraintsOf typ), Pretty (QVar typ)) =>
    Pretty (Tree QVars typ) where

    pPrint (QVars qvars) =
        Map.toList qvars
        <&> printVar
        <&> (Pretty.text "∀" <>) <&> (<> Pretty.text ".") & Pretty.hsep
        where
            printVar (q, c)
                | cP == mempty = pPrint q
                | otherwise = pPrint q <> Pretty.text "(" <> cP <> Pretty.text ")"
                where
                    cP = pPrint c

type instance Lens.Index (QVars typ) = QVar (GetKnot typ)
type instance Lens.IxValue (QVars typ) = TypeConstraintsOf (GetKnot typ)

instance Ord (QVar (GetKnot typ)) => Lens.Ixed (QVars typ)

instance Ord (QVar (GetKnot typ)) => Lens.At (QVars typ) where
    at k = _QVars . Lens.at k

type instance InferOf (Scheme v t) = Flip GTerm t

class Unify m t => MonadInstantiate m t where
    localInstantiations ::
        Tree (QVarInstances (UVarOf m)) t ->
        m a ->
        m a
    lookupQVar :: QVar t -> m (Tree (UVarOf m) t)

instance
    ( Monad m
    , HasInferredValue typ
    , Unify m typ
    , KTraversable varTypes
    , KNodesConstraint varTypes (MonadInstantiate m)
    , RTraversable typ
    , Infer m typ
    ) =>
    Infer m (Scheme varTypes typ) where

    {-# INLINE inferBody #-}
    inferBody (Scheme vars typ) =
        do
            foralls <- traverseK (Proxy @(MonadInstantiate m) #> makeQVarInstances) vars
            let withForalls =
                    foldMapK
                    (Proxy @(MonadInstantiate m) #> (:[]) . localInstantiations)
                    foralls
                    & foldl (.) id
            InferredChild typI typR <- inferChild typ & withForalls
            generalize (typR ^. inferredValue)
                <&> (Scheme vars typI, ) . MkFlip

inferType ::
    ( InferOf t ~ ANode t
    , KTraversable t
    , KNodesConstraint t HasInferredValue
    , Unify m t
    , MonadInstantiate m t
    ) =>
    Tree t (InferChild m k) ->
    m (Tree t k, Tree (InferOf t) (UVarOf m))
inferType x =
    case x ^? quantifiedVar of
    Just q -> lookupQVar q <&> (quantifiedVar # q, ) . MkANode
    Nothing ->
        do
            xI <- traverseK (const inferChild) x
            mapK (Proxy @HasInferredValue #> (^. inType . inferredValue)) xI
                & newTerm
                <&> (mapK (const (^. inRep)) xI, ) . MkANode

{-# INLINE makeQVarInstances #-}
makeQVarInstances ::
    Unify m typ =>
    Tree QVars typ -> m (Tree (QVarInstances (UVarOf m)) typ)
makeQVarInstances (QVars foralls) =
    traverse (newVar binding . USkolem) foralls <&> QVarInstances

{-# INLINE loadBody #-}
loadBody ::
    ( Unify m typ
    , HasChild varTypes typ
    , Ord (QVar typ)
    ) =>
    Tree varTypes (QVarInstances (UVarOf m)) ->
    Tree typ (GTerm (UVarOf m)) ->
    m (Tree (GTerm (UVarOf m)) typ)
loadBody foralls x =
    case x ^? quantifiedVar >>= getForAll of
    Just r -> GPoly r & pure
    Nothing ->
        case traverseK (const (^? _GMono)) x of
        Just xm -> newTerm xm <&> GMono
        Nothing -> GBody x & pure
    where
        getForAll v = foralls ^? getChild . _QVarInstances . Lens.ix v

class
    (Unify m t, HasChild varTypes t, Ord (QVar t)) =>
    HasScheme varTypes m t where

    hasSchemeRecursive ::
        Proxy varTypes -> Proxy m -> Proxy t ->
        Dict (KNodesConstraint t (HasScheme varTypes m))
    {-# INLINE hasSchemeRecursive #-}
    default hasSchemeRecursive ::
        KNodesConstraint t (HasScheme varTypes m) =>
        Proxy varTypes -> Proxy m -> Proxy t ->
        Dict (KNodesConstraint t (HasScheme varTypes m))
    hasSchemeRecursive _ _ _ = Dict

instance Recursive (HasScheme varTypes m) where
    recurse =
        hasSchemeRecursive (Proxy @varTypes) (Proxy @m) . p
        where
            p :: Proxy (HasScheme varTypes m t) -> Proxy t
            p _ = Proxy

-- | Load scheme into unification monad so that different instantiations share
-- the scheme's monomorphic parts -
-- their unification is O(1) as it is the same shared unification term.
{-# INLINE loadScheme #-}
loadScheme ::
    forall m varTypes typ.
    ( Monad m
    , KTraversable varTypes
    , KNodesConstraint varTypes (Unify m)
    , HasScheme varTypes m typ
    ) =>
    Tree Pure (Scheme varTypes typ) ->
    m (Tree (GTerm (UVarOf m)) typ)
loadScheme (Pure (Scheme vars typ)) =
    do
        foralls <- traverseK (Proxy @(Unify m) #> makeQVarInstances) vars
        wrapM (Proxy @(HasScheme varTypes m) #>> loadBody foralls) typ

saveH ::
    forall typ varTypes m.
    (Monad m, HasScheme varTypes m typ) =>
    Tree (GTerm (UVarOf m)) typ ->
    StateT (Tree varTypes QVars, [m ()]) m (Tree Pure typ)
saveH (GBody x) =
    withDict (hasSchemeRecursive (Proxy @varTypes) (Proxy @m) (Proxy @typ)) $
    traverseK (Proxy @(HasScheme varTypes m) #> saveH) x <&> (_Pure #)
saveH (GMono x) =
    unwrapM (Proxy @(HasScheme varTypes m) #>> f) x & lift
    where
        f v =
            semiPruneLookup v
            <&>
            \case
            (_, UTerm t) -> t ^. uBody
            (_, UUnbound{}) -> error "saveScheme of non-toplevel scheme!"
            _ -> error "unexpected state at saveScheme of monomorphic part"
saveH (GPoly x) =
    lookupVar binding x & lift
    >>=
    \case
    USkolem l ->
        do
            r <- scopeConstraints <&> (<> l) >>= newQuantifiedVariable & lift
            Lens._1 . getChild %=
                (\v -> v & _QVars . Lens.at r ?~ l :: Tree QVars typ)
            Lens._2 %= (bindVar binding x (USkolem l) :)
            let result = _Pure . quantifiedVar # r
            UResolved result & bindVar binding x & lift
            pure result
    UResolved v -> pure v
    _ -> error "unexpected state at saveScheme's forall"

saveScheme ::
    ( KNodesConstraint varTypes OrdQVar
    , KPointed varTypes
    , HasScheme varTypes m typ
    ) =>
    Tree (GTerm (UVarOf m)) typ ->
    m (Tree Pure (Scheme varTypes typ))
saveScheme x =
    do
        (t, (v, recover)) <-
            runStateT (saveH x)
            ( pureK (Proxy @OrdQVar #> QVars mempty)
            , []
            )
        _Pure # Scheme v t <$ sequence_ recover
