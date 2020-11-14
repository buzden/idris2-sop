module Generics.Derive

import public Generics.SOP

import Language.Reflection.Syntax
import Language.Reflection.Types

%language ElabReflection

%default covering

||| Utility data type for deriving interface implementations
||| automatically. See implementation of `Eq'` and `Ord'`
||| for examples.
export
record GenericUtil where
  constructor MkGenericUtil

  ||| The underlying type info containing the list and names
  ||| of data constructors plus their arguments as well as
  ||| the data type's name and type arguments.
  typeInfo           : ParamTypeInfo

  ||| Fully applied data type, i.e. `var "Either" .$ var "a" .$ var "b"`
  appliedType        : TTImp 

  ||| The names of type parameters
  paramNames         : List Name

  ||| Types of constructor arguments where at least one
  ||| type parameter makes an appearance. These are the
  ||| `tpe` fields of `ExplicitArg` where `hasParam`
  ||| is set to true. See the documentation of `ExplicitArg`
  ||| when this is the case
  argTypesWithParams : List TTImp

export
genericUtil : ParamTypeInfo -> GenericUtil
genericUtil ti = let pNames = map fst $ params ti
                     appTpe = appNames (name ti) pNames
                     twps   = concatMap hasParamTypes ti.cons
                  in MkGenericUtil ti appTpe pNames twps

||| Generates the name of an interface's implementation function
export
implName : GenericUtil -> String -> Name
implName g interfaceName =  UN $ "impl" ++ interfaceName
                                        ++ nameStr g.typeInfo.name

||| Syntax tree and additional info about the
||| implementation function of an interface.
|||
||| With 'implementation function', we mean the following:
||| When deriving an interface implementation, the elaborator
||| creates a function returning the corresponding record value:
|||
||| ```idris exampe
||| public export
||| implEqEither : {0 a : _} -> {0 b : _} -> Eq a => Eq b => Eq (Either a b)
||| implEqEither = ?res
||| ```
public export
record InterfaceImpl where
  constructor MkInterfaceImpl
  ||| The interface's name, for instance "Eq" ord "Ord".
  ||| This is used to generate the name of the
  ||| implementation function.
  interfaceName : String

  ||| Visibility of the implementation function.
  visibility    : Visibility

  ||| Actual implementation of the implementation function.
  ||| This will be right hand side of the sole pattern clause
  ||| in the function definition.
  |||
  ||| Here is an example, how this will be used:
  |||
  ||| ```idirs example
  ||| def function [var function .= impl] 
  ||| ```
  impl          : TTImp

  ||| Full type of the implementation function
  |||
  ||| Example:
  |||
  ||| ```idirs example
  ||| `(Eq a => Eq b => Eq (Either a b))
  ||| ```
  type          : TTImp

||| Alias for a function from `GenericUtil`
||| to `InterfaceImpl`. A value of this type must
||| be provided and passed to `derive` for each interface
||| that should be derived automatically.
public export
MkImplementation : Type
MkImplementation = GenericUtil -> InterfaceImpl

private
implDecl : GenericUtil -> MkImplementation -> List Decl
implDecl g f = let (MkInterfaceImpl iname vis impl type) = f g
                   function = implName g iname

                in [ interfaceHint vis function type
                   , def function [var function .= impl] ]

private
deriveDecls : Name -> List MkImplementation -> Elab (List Decl)
deriveDecls name fs = mkDecls <$> getParamInfo' name 
  where mkDecls : ParamTypeInfo -> List Decl
        mkDecls pi = let g = genericUtil pi
                      in concatMap (implDecl g) fs
                  

export
derive : Name -> List MkImplementation -> Elab ()
derive name fs = do decls <- deriveDecls name fs
                    declare decls

--------------------------------------------------------------------------------
--          Generic
--------------------------------------------------------------------------------

private
ConNames : Type
ConNames = (Name, List String, List TTImp)

||| Name of record `Generic`'s constructor.
export
mkGeneric : Name
mkGeneric = singleCon "Generic"

-- Applies the proper n-ary sum constructor to a list
-- of arguments. `k` is the index of the data type's
-- constructor.
private
mkSOP : (k : Int) -> (args : List TTImp) -> TTImp
mkSOP k args     = if k <= 0 then `(Z) .$ listOf args
                             else `(S) .$ mkSOP (k-1) args

||| Creates the syntax tree for the code of the given data type.
||| We export this here, since it might be useful elsewhere.
export
mkCode : ParamTypeInfo -> TTImp
mkCode = listOf . map (listOf . map tpe . explicitArgs) . cons

private
fromClause : (Int,ConNames) -> Clause
fromClause (k,(con,ns,vars)) = bindAll con ns .= mkSOP k vars

private
fromToIdClause : (Int,ConNames) -> Clause
fromToIdClause (k,(con,ns,vars)) = bindAll con ns .= `(Refl)

private
toClause : (Int,ConNames) -> Clause
toClause (k,(con,ns,vars)) = mkSOP k (map bindVar ns) .= appAll con vars

private
toFromIdClause : (Int,ConNames) -> Clause
toFromIdClause (k,(con,ns,vars)) = mkSOP k (map bindVar ns) .= `(Refl)

private
zipWithIndex : List a -> List (Int,a)
zipWithIndex as = run 0 as
  where run : Int -> List a -> List (Int,a)
        run _ []     = []
        run k (h::t) = (k,h) :: run (k+1) t

private
conNames : ParamCon -> ConNames
conNames (MkParamCon con args) = let ns   = map (nameStr . name) args
                                     vars = map varStr ns
                                  in (con, ns, vars)

export
Generic' : MkImplementation
Generic' g =
  let names    = zipWithIndex (map conNames g.typeInfo.cons)
      genType  = `(Generic) .$ g.appliedType .$ mkCode g.typeInfo
      funType  = piAllImplicit  genType g.paramNames
      x        = lambdaArg "x"
      varX     = var "x"

      from     = x .=> iCase varX implicitFalse (map fromClause names)
      to       = x .=> iCase varX implicitFalse (map toClause names)
      fromToId = x .=> iCase varX implicitFalse (map fromToIdClause names)
      toFromId = x .=> iCase varX implicitFalse (map toFromIdClause names)

      impl     = appAll mkGeneric [from,to,fromToId,toFromId]

   in MkInterfaceImpl "Generic" Public impl funType
