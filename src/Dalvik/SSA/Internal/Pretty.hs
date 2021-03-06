{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | This module defines a pretty printer for the SSA-based IR.
--
-- All of this is very subject to change.
module Dalvik.SSA.Internal.Pretty where

import Data.ByteString ( ByteString )
import qualified Data.Foldable as F
import Data.Int ( Int64 )
import qualified Data.List as L
import qualified Data.Vector as V
import Text.PrettyPrint.HughesPJClass as PP
import qualified Text.PrettyPrint.GenericPretty as GP

import Dalvik.MUTF8
import Dalvik.SSA.Types

safeString :: ByteString -> Doc
safeString = PP.text . decodeMUTF8

prettyTypeDoc :: Type -> Doc
prettyTypeDoc t =
  case t of
    VoidType -> PP.text "void"
    ByteType -> PP.text "byte"
    ShortType -> PP.text "short"
    IntType -> PP.text "int"
    LongType -> PP.text "long"
    FloatType -> PP.text "float"
    DoubleType -> PP.text "double"
    CharType -> PP.text "char"
    BooleanType -> PP.text "boolean"
    ArrayType t' -> prettyTypeDoc t' <> PP.text "[]"
    ReferenceType c -> PP.text $ humanClassName c
    UnknownType -> PP.text "<unknown>"

prettyParameterDoc :: Parameter -> Doc
prettyParameterDoc p = PP.char '%' <> safeString (parameterName p)

prettyConstantDoc :: Constant -> Doc
prettyConstantDoc c =
  case c of
    ConstantInt _ i -> PP.text (show i)
    ConstantString _ s -> PP.doubleQuotes $ safeString s
    ConstantClass _ klass -> prettyTypeDoc klass <> PP.text ".class"

valueDoc :: Value -> Doc
valueDoc v =
  case v of
    ConstantV c -> prettyConstantDoc c
    ParameterV p -> prettyParameterDoc p
    InstructionV i -> PP.char '%' <> PP.int (instructionId i)

-- | Generate a doc with:
--
-- > %<id> <-
--
-- Note it will include a space after the arrow, so the
-- caller can just continue directly.
instBindDoc :: Instruction -> Doc
instBindDoc i = PP.char '%' <> PP.int (instructionId i)
                  <+> PP.text "<-"

arrayElementTypeDoc :: Type -> Doc
arrayElementTypeDoc t =
  case t of
    ArrayType t' -> prettyTypeDoc t'
    _ -> prettyTypeDoc UnknownType

prettyInstructionDoc :: Instruction -> Doc
prettyInstructionDoc i =
  case i of
    Return { returnValue = Nothing } -> PP.text "return"
    Return { returnValue = Just rv } ->
      PP.text "return" <+> valueDoc rv
    MoveException {} -> instBindDoc i <+>
                          PP.text "move-exception" <+>
                          prettyTypeDoc (instructionType i)
    MonitorEnter { monitorReference = r } ->
      PP.text "monitor-enter" <+> valueDoc r
    MonitorExit { monitorReference = r } ->
      PP.text "monitor-exit" <+> valueDoc r
    CheckCast { castReference = r, castType = t } ->
      instBindDoc i <+> PP.text "check-cast" <+> prettyTypeDoc (valueType r) <+>
        valueDoc r <+> PP.text "to" <+> prettyTypeDoc t
    InstanceOf { instanceOfReference = r
               , instanceOfType = iot
               } ->
      instBindDoc i <+> PP.text "instance-of" <+>
        valueDoc r <+> PP.text "as" <+> prettyTypeDoc iot
    ArrayLength { arrayReference = r } ->
      instBindDoc i <+> PP.text "array-length" <+> valueDoc r
    NewInstance {} ->
      instBindDoc i <+> PP.text "new-instance" <+>
        prettyTypeDoc (instructionType i)
    NewArray { newArrayLength = len, newArrayContents = Nothing } ->
      instBindDoc i <+> PP.text "new-array" <+>
        arrayElementTypeDoc (instructionType i) <+>
        valueDoc len
    NewArray { newArrayContents = Just vs } ->
      instBindDoc i <+> PP.text "new-array" <+>
        arrayElementTypeDoc (instructionType i) <+>
        arrayLiteralDoc (map valueDoc vs)
    FillArray { fillArrayReference = r, fillArrayContents = vs } ->
      PP.text "fill-array" <+> valueDoc r  <+>
        arrayLiteralDoc (map (PP.text . show) vs)
    Throw { throwReference = r } ->
      PP.text "throw" <+> valueDoc r
    ConditionalBranch { branchOperand1 = op1
                      , branchOperand2 = op2
                      , branchTestType = tt
                      , branchTarget = tb
                      , branchFallthrough = fb
                      } ->
      PP.text "if" <+> valueDoc op1 <+> ifopDoc tt <+>
        valueDoc op2 <+> PP.text "go to block" <+>
        blockIdDoc tb <+> PP.text "otherwise go to block" <+>
        blockIdDoc fb
    UnconditionalBranch { branchTarget = t } ->
      PP.text "goto block" <+> blockIdDoc t
    Switch { switchValue = v
           , switchTargets = ts
           , switchFallthrough = ft
           } ->
      PP.text "switch" <+> valueDoc v <+>
        arrayLiteralDoc (map switchCaseDoc ts) <+>
        PP.text "fallthrough to" <+> blockIdDoc ft
    Compare { compareOperation = op
            , compareOperand1 = op1
            , compareOperand2 = op2
            } ->
      instBindDoc i <+> PP.text "compare" <+> cmpopDoc op <+>
        valueDoc op1 <> PP.char ',' <+> valueDoc op2
    UnaryOp { unaryOperand = v
            , unaryOperation = op
            } ->
      instBindDoc i <+> unaryOpDoc op v
    BinaryOp { binaryOperand1 = op1
             , binaryOperand2 = op2
             , binaryOperation = op
             } ->
      instBindDoc i <+> binaryOpDoc op <+> valueDoc op1 <+> valueDoc op2
    ArrayGet { arrayReference = r
             , arrayIndex = ix
             } ->
      instBindDoc i <+> PP.text "array-get" <+> valueDoc r <+>
        PP.text "at" <+> valueDoc ix
    ArrayPut { arrayReference = r
             , arrayIndex = ix
             , arrayPutValue = v
             } ->
      PP.text "array-put" <+> valueDoc v <+> PP.text "into" <+>
        valueDoc r <+> PP.text "at" <+> valueDoc ix
    StaticGet { staticOpField = f } ->
      instBindDoc i <+> PP.text "static-get" <+>
        prettyStaticFieldRefDoc f
    StaticPut { staticOpField = f, staticOpPutValue = v } ->
      PP.text "static-put" <+> valueDoc v <+> PP.text "into" <+>
        prettyStaticFieldRefDoc f
    InstanceGet { instanceOpReference = r, instanceOpField = f } ->
      instBindDoc i <+> PP.text "instance-get" <+> bareFieldDoc f <+>
        PP.text "from" <+> valueDoc r
    InstancePut { instanceOpReference = r
                , instanceOpField = f
                , instanceOpPutValue = v
                } ->
      PP.text "instance-put" <+> valueDoc v <+> PP.text "into" <+>
        bareFieldDoc f <+> PP.text "in" <+> valueDoc r
    InvokeVirtual { invokeVirtualKind = k
                  , invokeVirtualMethod = m
                  , invokeVirtualArguments = vs
                  } ->
      let beginning = case instructionType i of
            VoidType -> (PP.empty <>)
            _ -> (instBindDoc i <+>)
      in beginning $ PP.text "invoke" <+> prettyVirtualKindDoc k <+>
           prettyMethodRefDoc m <> prettyArgumentList (F.toList vs)
    InvokeDirect { invokeDirectKind = k
                 , invokeDirectMethod = m
                 , invokeDirectArguments = vs
                 } ->
      let beginning = case instructionType i of
            VoidType -> (PP.empty <>)
            _ -> (instBindDoc i <+>)
      in beginning $ PP.text "invoke" <+> prettyDirectKindDoc k <+>
           prettyMethodRefDoc m <> prettyArgumentList vs
    Phi { phiValues = ivs } ->
      instBindDoc i <+> PP.text "phi" <+>
        arrayLiteralDoc (map phiValueDoc ivs)

phiValueDoc :: (BasicBlock, Value) -> Doc
phiValueDoc (bb, v) =
  PP.parens $ blockIdDoc bb <> PP.char ',' <+> valueDoc v

prettyMethodRefDoc :: MethodRef -> Doc
prettyMethodRefDoc mref =
  prettyTypeDoc (methodRefClass mref) <> PP.char '.' <> safeString (methodRefName mref)

prettyVirtualKindDoc :: InvokeVirtualKind -> Doc
prettyVirtualKindDoc k =
  case k of
    MethodInvokeInterface -> PP.text "interface"
    MethodInvokeSuper -> PP.text "super"
    MethodInvokeVirtual -> PP.text "virtual"

prettyDirectKindDoc :: InvokeDirectKind -> Doc
prettyDirectKindDoc k =
  case k of
    MethodInvokeStatic -> PP.text "static"
    MethodInvokeDirect -> PP.text "direct"

bareFieldDoc :: Field -> Doc
bareFieldDoc = safeString . fieldName

-- | Pretty print a field being referenced from an instruction
prettyStaticFieldRefDoc :: Field -> Doc
prettyStaticFieldRefDoc f = prettyTypeDoc (fieldClass f) <> PP.char '.' <> safeString (fieldName f)

binaryOpDoc :: Binop -> Doc
binaryOpDoc op =
  case op of
    Add -> PP.text "add"
    Sub -> PP.text "sub"
    Mul -> PP.text "mul"
    Div -> PP.text "div"
    Rem -> PP.text "rem"
    And -> PP.text "and"
    Or -> PP.text "or"
    Xor -> PP.text "xor"
    Shl -> PP.text "shl"
    Shr -> PP.text "shr"
    UShr -> PP.text "ushr"
    RSub -> PP.text "rsub"

instance PP.Pretty Binop where
  pPrint = binaryOpDoc

unop :: Unop -> Doc
unop op =
  case op of
    NegInt -> PP.text "neg"
    NotInt -> PP.text "not"
    NegLong -> PP.text "neg"
    NotLong -> PP.text "not"
    NegFloat -> PP.text "neg"
    NegDouble -> PP.text "neg"
    Convert _ _ -> PP.text "convert"

instance PP.Pretty Unop where
  pPrint = unop

unaryOpDoc :: Unop -> Value -> Doc
unaryOpDoc op v =
  case op of
    NegInt -> PP.text "neg" <+> valueDoc v
    NotInt -> PP.text "not" <+> valueDoc v
    NegLong -> PP.text "neg" <+> valueDoc v
    NotLong -> PP.text "not" <+> valueDoc v
    NegFloat -> PP.text "neg" <+> valueDoc v
    NegDouble -> PP.text "neg" <+> valueDoc v
    Convert t1 t2 -> PP.text "convert" <+> valueDoc v <+>
      PP.text "from" <+> convertTypeDoc t1 <+> PP.text "to" <+>
      convertTypeDoc t2

convertTypeDoc :: CType -> Doc
convertTypeDoc t =
  case t of
    Byte -> PP.text "byte"
    Char -> PP.text "char"
    Short -> PP.text "short"
    Int -> PP.text "int"
    Long -> PP.text "long"
    Float -> PP.text "float"
    Double -> PP.text "double"

instance PP.Pretty CType where
  pPrint = convertTypeDoc

cmpopDoc :: CmpOp -> Doc
cmpopDoc o =
  case o of
    CLFloat -> PP.text "float lt bias"
    CGFloat -> PP.text "float gt bias"
    CLDouble -> PP.text "double lt bias"
    CGDouble -> PP.text "double gt bias"
    CLong -> PP.text "long"

instance PP.Pretty CmpOp where
  pPrint = cmpopDoc

switchCaseDoc :: (Int64, BasicBlock) -> Doc
switchCaseDoc (i, target) =
  PP.parens (PP.text (show i) <+> PP.text "-> block" <+> blockIdDoc target)

ifopDoc :: IfOp -> Doc
ifopDoc o =
  case o of
    Eq -> PP.text "eq"
    Ne -> PP.text "ne"
    Lt -> PP.text "lt"
    Le -> PP.text "le"
    Gt -> PP.text "gt"
    Ge -> PP.text "ge"

instance PP.Pretty IfOp where
  pPrint = ifopDoc

blockIdDoc :: BasicBlock -> Doc
blockIdDoc = PP.int . basicBlockNumber

arrayLiteralDoc :: [Doc] -> Doc
arrayLiteralDoc = PP.brackets . commaSepList

commaSepList :: [Doc] -> Doc
commaSepList = PP.hcat . L.intersperse (PP.text ", ")


prettyArgumentList :: [Value] -> Doc
prettyArgumentList = PP.parens . commaSepList . map valueDoc

prettyFormalList :: [Parameter] -> Doc
prettyFormalList = PP.parens . commaSepList . map prettyFormalParamDoc

prettyFormalParamDoc :: Parameter -> Doc
prettyFormalParamDoc p = prettyTypeDoc (parameterType p) <+> safeString (parameterName p)

prettyBlockDoc :: BasicBlock -> Doc
prettyBlockDoc bb@BasicBlock { basicBlockNumber = bnum
                             , _basicBlockInstructions = insns
                             } =
  (PP.int bnum <> PP.text ":\t ;" <+> preds) $+$ PP.nest 2 insnDoc
  where
    insnDoc = PP.vcat $ map prettyInstructionDoc $ V.toList insns
    pblocks = basicBlockPredecessors bb
    preds = case pblocks of
      [] -> PP.text "no predecessors"
      _ -> arrayLiteralDoc $ map (PP.int . basicBlockNumber) pblocks

prettyMethodDoc :: Maybe DexFile -> Method -> Doc
prettyMethodDoc mdf m@Method { methodReturnType = rt
                             , methodName = mname
                             , methodAccessFlags = flags
                             } =
  case methodBody m of
    Nothing -> annotDoc $+$ intro
    Just blocks -> annotDoc $+$ intro <+> PP.char '{' $+$ PP.vcat (map prettyBlockDoc blocks) $+$ end
  where
    ps = methodParameters m
    intro = prettyTypeDoc rt <+> safeString mname <> prettyFormalList ps <+> PP.text (flagsString AMethod flags)
    end = PP.char '}'

    annots = maybe [] (\df -> dexMethodAnnotation df m) mdf
    annotDoc = PP.vcat (map prettyVisibleAnnotation annots)

prettyFieldDefDoc :: (AccessFlags, Field) -> Doc
prettyFieldDefDoc (flags, fld) =
  prettyTypeDoc (fieldType fld) <+> safeString (fieldName fld) <+> PP.text (flagsString AField flags)

prettyClassDoc :: Maybe DexFile -> Class -> Doc
prettyClassDoc mdf klass =
  annotDoc $+$ header $+$ meta $+$ body $+$ end
  where
    header = PP.text (flagsString AClass (classAccessFlags klass)) <+> PP.text "class" <+> safeString (className klass) <+> PP.char '{'
    staticFields = map prettyFieldDefDoc (classStaticFields klass)
    instanceFields = map prettyFieldDefDoc (classInstanceFields klass)
    static = PP.vcat (staticFields ++ directMethods)
    virtual = PP.vcat (instanceFields ++ virtualMethods)
    directMethods = L.intersperse (PP.text "") $ map (prettyMethodDoc mdf) (classDirectMethods klass)
    virtualMethods = L.intersperse (PP.text "") $ map (prettyMethodDoc mdf) (classVirtualMethods klass)
    body = PP.nest 2 (static $+$ PP.text "" $+$ virtual)
    super = case classParent klass of
      Nothing -> PP.empty
      Just sc -> PP.text "Superclass:" <+> prettyTypeDoc sc
    interfaces = PP.text "Interfaces:" $+$
                   PP.nest 2 (PP.vcat (map prettyTypeDoc (classInterfaces klass))) $+$ PP.text ""
    meta = PP.nest 2 (super $+$ interfaces)
    end = PP.char '}'

    annots = maybe [] (\df -> dexClassAnnotation df klass) mdf
    annotDoc = PP.vcat (map prettyVisibleAnnotation annots)

prettyVisibleAnnotation :: VisibleAnnotation -> Doc
prettyVisibleAnnotation va =
  prettyAnnotation (annotationValue va) <+> ";" <+> prettyAnnotationVisibility (annotationVisibility va)

prettyAnnotation :: Annotation -> Doc
prettyAnnotation a =
  "@" <> prettyTypeDoc (annotationType a) <> args
  where
    args = case annotationArguments a of
      [] -> PP.empty
      as -> PP.parens (PP.hcat (PP.punctuate ", " (map prettyArg as)))
    prettyArg (name, aval) = PP.text (decodeMUTF8 name) <> "=" <> prettyAnnotationValue aval

prettyAnnotationValue :: AnnotationValue -> Doc
prettyAnnotationValue av =
  case av of
    AVInt i -> PP.integer i
    AVChar c -> PP.quotes (PP.char c)
    AVFloat f -> PP.float f
    AVDouble d -> PP.double d
    AVString s -> PP.doubleQuotes (PP.text (decodeMUTF8 s))
    AVType t -> prettyTypeDoc t
    AVField f -> PP.text (decodeMUTF8 (fieldName f))
    AVMethod m -> PP.text (decodeMUTF8 (methodRefName m))
    AVEnum e -> PP.text (decodeMUTF8 (fieldName e))
    AVArray vals -> PP.brackets (PP.hcat (PP.punctuate ", " (map prettyAnnotationValue vals)))
    AVAnnotation a -> prettyAnnotation a
    AVNull -> "null"
    AVBool b -> if b then "true" else "false"

prettyAnnotationVisibility :: AnnotationVisibility -> Doc
prettyAnnotationVisibility v =
  case v of
    AVSystem -> "<system>"
    AVBuild -> "<build>"
    AVRuntime -> "<runtime>"

prettyDexDoc :: DexFile -> Doc
prettyDexDoc df = PP.vcat (map (prettyClassDoc (Just df)) (dexClasses df))

instance PP.Pretty InvokeVirtualKind where
  pPrint = prettyVirtualKindDoc

instance PP.Pretty InvokeDirectKind where
  pPrint = prettyDirectKindDoc

instance Show Instruction where
  show = PP.prettyShow

instance PP.Pretty Instruction where
  pPrint = prettyInstructionDoc

instance Show MethodRef where
  show = PP.prettyShow

instance PP.Pretty MethodRef where
  pPrint = prettyMethodRefDoc

instance Show Field where
  show = PP.prettyShow

instance PP.Pretty Field where
  pPrint = bareFieldDoc

instance Show Class where
  show = PP.prettyShow

instance PP.Pretty Class where
  pPrint = prettyClassDoc Nothing

instance Show Method where
  show = PP.prettyShow

instance PP.Pretty Method where
  pPrint = prettyMethodDoc Nothing

instance Show Parameter where
  show = PP.prettyShow

instance PP.Pretty Parameter where
  pPrint = prettyFormalParamDoc

instance PP.Pretty Type where
  pPrint = prettyTypeDoc

instance GP.Out Type where
  doc = prettyTypeDoc
  docPrec _ = prettyTypeDoc

instance Show BasicBlock where
  show = PP.prettyShow

instance PP.Pretty BasicBlock where
  pPrint = prettyBlockDoc

instance Show Value where
  show = PP.prettyShow

instance PP.Pretty Value where
  pPrint = valueDoc

instance Show Constant where
  show = PP.prettyShow

instance PP.Pretty Constant where
  pPrint = prettyConstantDoc

instance Show DexFile where
  show = PP.prettyShow

instance PP.Pretty DexFile where
  pPrint = prettyDexDoc
