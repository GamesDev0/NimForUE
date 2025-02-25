import std/[options, strutils, sugar, sequtils, strformat,  genasts, macros, importutils]
include ../unreal/definitions
import ../utils/[utils, ueutils]
import ../unreal/core/containers/[unrealstring, array, map, set]
import ../unreal/coreuobject/[uobjectflags]
import nuemacrocache, models, modelconstructor, projectinstrospect, uebindcore
import modulerules
import ../../buildscripts/nimforueconfig #probably nimforueconfig should be removed from buildscripts

  # macro ex*(a:untyped):untyped = a
func genPropsAsRecList(ueType: UEType, rule: UERule = uerNone) : NimNode 

func genProp(typeDef : UEType, prop : UEField) : NimNode = 
  let ptrName = ident typeDef.name & "Ptr"
  
  let className = typeDef.name.substr(1)

  let typeNode = case prop.kind:
          of uefProp: getTypeNodeFromUProp(prop, isVarContext=false)
          else: newEmptyNode() #No Support 
  let typeNodeAsReturnValue = case prop.kind:
              of uefProp: prop.getTypeNodeForReturn(getTypeNodeFromUProp(prop, isVarContext=true))
              else: newEmptyNode()#No Support as UProp getter/Seter
  
  
  let propIdent = ident (prop.name[0].toLowerAscii() & prop.name.substr(1)).nimToCppConflictsFreeName()


  #bools are handled differently:
  let actualGetter = 
    if prop.uePropType == "bool": 
      genAst():
        getValueFromBoolProp(prop, obj)
    else:
      genAst(typeNode):
        getPropertyValuePtr[typeNode](prop, obj)[]
  let actualSetter = 
    if prop.uePropType == "bool": 
      genAst():
        setValueInBoolProp(prop, obj, value)
    else:
      genAst(typeNode):
        setPropertyValuePtr[typeNode](prop, obj, value.addr)

  #Notice we generate two set properties one for nim and the other for code gen due to cpp
  #not liking the equal in the ident name
  
  result = 
    genAst(propIdent, ptrName, typeNode, className, actualGetter, actualSetter, propUEName = prop.name, typeNodeAsReturnValue):
      proc `propIdent`* (obj {.inject.} : ptrName ) : typeNodeAsReturnValue {.exportcpp.} =
        let prop {.inject.} = getClassByName(className).getFPropertyByName(propUEName)
        actualGetter
      
      proc `propIdent=`* (obj {.inject.} : ptrName, val {.inject.} :typeNode)  = 
        var value {.inject.} : typeNode = val
        let prop {.inject.} = getClassByName(className).getFPropertyByName(propUEName)
        actualSetter

      proc `set propIdent`* (obj {.inject.} : ptrName, val {.inject.} :typeNode)  {.exportcpp.} = 
        var value {.inject.} : typeNode = val
        let prop {.inject.} = getClassByName(className).getFPropertyByName(propUEName)
        actualSetter
  

func genParamInFnBodyAsType(funField:UEField) : NimNode = 
  let returnProp = funField.signature.filter(isReturnParam).head()
  #make sure we remove the out flag so we dont emit var on type variables which is not allowed
  var funField = funField

  for s in funField.signature.mitems:
    if  s.isReturnParam:
      s.propFlags = CPF_ReturnParm #remove out flag before the signatureCall, cant do and for some reason. Maybe a bug?
    elif s.isOutParam:
      s.propFlags = CPF_None #remove out flag before the signatureCall, cant do and for some reason. Maybe a bug?

  let paramsInsideFuncDef = nnkTypeSection.newTree([nnkTypeDef.newTree([identWithInject "Params", newEmptyNode(), 
              nnkObjectTy.newTree([
                newEmptyNode(), newEmptyNode(),  
                nnkRecList.newTree(
                  funField.signatureAsNode(identWrapper, isDefaultValueContext=false) &
                  returnProp.map(prop=>
                    @[nnkIdentDefs.newTree([ident("returnValue"), 
                              getTypeNodeFromUProp(prop, isVarContext = false),
                              # ident prop.uePropType, 
                              newEmptyNode()])]).get(@[])
                )])
            ])])

  
  paramsInsideFuncDef

func getGenFuncName(funField : UEField) : string = funField.name.firstToLow().ueNameToNimName
#this is used for both, to generate regular function binds and delegate broadcast/execute functions
#for the most part the same code is used for both
#this is also used for native function implementation but the ast is changed afterwards
#Returns a tuple with the forward declaration and the actual function 
func genFunc*(typeDef : UEType, funField : UEField) : tuple[fw:NimNode, impl:NimNode] = 
  let isStatic = FUNC_Static in funField.fnFlags
  let clsName = typeDef.name.substr(1)

  let formalParams = genFormalParamsInFunctionSignature(typeDef, funField, "self")

  let generateObjForStaticFunCalls = 
    if isStatic: 
      genAst(clsName=newStrLitNode(clsName)): 
        let self {.inject.} = nimforue.getDefaultObjectFromClassName(clsName)
    else: newEmptyNode()

  
  let processFn = 
    case typeDef.kind:
    of uetDelegate:
      case typeDef.delKind:
        of uedelDynScriptDelegate:
          genAst(): self.processDelegate(param.addr)
        of uedelMulticastDynScriptDelegate:
          genAst(): self.processMulticastDelegate(param.addr)
    else: genAst(clsName=newStrLitNode(clsName)): 
      let fn {.inject, used.} = uobject.findFuncByName(uobject.getClass(ueCast[UObject](self)), fnName)
      self.processEvent(fn, param.addr)

  let outParams = 
    nnkStmtList.newTree(
      funField.signature
        .filterIt(it.isOutParam and not it.isReturnParam)
        .mapIt(it.name)
        .mapIt(nnkAsgn.newTree(ident(it.firstToLow().ueNameToNimName), nnkDotExpr.newTree(ident("param"), ident(it.firstToLow().ueNameToNimName))))
    )

  let returnCall = if funField.doesReturn(): 
            genAst(): 
              return param.returnValue
           else: newEmptyNode()
  let paramInsideBodyAsType = genParamInFnBodyAsType(funField)
  let paramObjectConstrCall = nnkObjConstr.newTree(@[ident "Params"] &  #creates Params(param0:param0, param1:param1)
                funField.signature
                  .filter(prop=>not isReturnParam(prop))
                  .map(param=>ident(param.name.firstToLow().ueNameToNimName()))
                  .map(param=>nnkExprColonExpr.newTree(param, param))
              )
  let paramDeclaration = nnkVarSection.newTree(nnkIdentDefs.newTree([identWithInject "param", newEmptyNode(), paramObjectConstrCall]))

  var fnBody = genAst(uFnName=newStrLitNode(funField.actualFunctionName), paramInsideBodyAsType, paramDeclaration, generateObjForStaticFunCalls, processFn, returnCall, outParams):
    paramInsideBodyAsType
    paramDeclaration
    let fnName {.inject, used .} = n uFnName
    generateObjForStaticFunCalls
    processFn
    outParams
    returnCall

  var pragmas = 
    when WithEditor:
      nnkPragma.newTree(
        nnkExprColonExpr.newTree(ident "exportcpp", newStrLitNode("$1_"))
        ) #export the func with an underscore to avoid collisions
    else: newEmptyNode()

  # when defined(windows):
  #   pragmas.add(ident("thiscall")) #I Dont think this is necessary
  let forwardDeclaration = 
   nnkProcDef.newTree([
              identPublic funField.getGenFuncName(), 
              newEmptyNode(), newEmptyNode(), 
              formalParams, 
              pragmas, newEmptyNode(),
            ])
  var impl = forwardDeclaration
  impl.add(fnBody)
  (forwardDeclaration,impl)


func genInterfaceConverers*(ueType:UEType) : NimNode =   
  let typeNamePtr = ident ueType.name & "Ptr"
  func genConverter(interName:string) : NimNode = 
    let interfaceName = ident interName
    let interfacePtrName = ident interName & "Ptr"
    let fnName = ident ueType.name & "to" & interName
    genAst(fnName,typeNamePtr, interfaceName, interfacePtrName):      
      when not declared(fnName):
        converter fnName*(self {.inject.} : typeNamePtr): interfacePtrName =  cast[interfacePtrName](self)
  
  nnkStmtList.newTree(ueType.interfaces.mapIt(genConverter(it)))

func getClassTemplate*(typeDef: UEType ) : string =  
  var cppInterfaces = typeDef.interfaces.filterIt(it[0] == 'I').mapIt("public " & it).join(", ")
  if cppInterfaces != "":
    cppInterfaces = ", " & cppInterfaces
  let defaultCtor = if typeDef.hasObjInitCtor: "" else: "$1()=default;" #the default ctor will be autogen by Nim (dsl only, TODO make sure only dsl types do this). Also not used so far (it may be needed down the road)

#The constructor is called internally in emittypes
  &"""
struct $1 : public $3{cppInterfaces} {{
  {defaultCtor}
  $1(FVTableHelper& Helper) : $3(Helper) {{}}
  $2  
}};
"""


func genUClassTypeDef(typeDef : UEType, rule : UERule = uerNone, typeExposure: UEExposure) : NimNode =

  let props = nnkStmtList.newTree(
        typeDef.fields
          .filter(prop=>prop.kind==uefProp)
          .map(prop=>genProp(typeDef, prop)))

  let funcs = nnkStmtList.newTree(
          typeDef.fields
             .filter(prop=>prop.kind==uefFunction)
             .map(fun=>genFunc(typeDef, fun).impl))

  let typeDecl = 
    if rule == uerCodeGenOnlyFields or typeDef.forwardDeclareOnly or 
      typeDef.metadata.filterIt(it.name.toLower() == NoDeclMetadataKey.toLower()).any(): 
        newEmptyNode()
    else: 
      let ptrName = ident typeDef.name & "Ptr"
      let parent = ident typeDef.parent      
      case typeExposure:
      of uexDsl:
        let outputHeader = newLit OutPutHeader
        let typeSection = genAst(name = ident typeDef.name, ptrName, parent, outputHeader):
                    type 
                      name* {.inject, exportc, inheritable, codegenDecl:"placeholder".} = object of parent #TODO OF BASE CLASS 
                      ptrName* {.inject.} = ptr name
        #Replaces the header pragma vale 'placehodler' from above. For some reason it doesnt want to pick the value directly
        typeSection[0][0][^1][^1][^1] = newLit getClassTemplate(typeDef)  
        # typeSection[0][^1][^1] = genPropsAsRecList(typeDef, rule)
        typeSection
      of uexExport:
        newEmptyNode()       
      of uexImport:
        newEmptyNode()

  # if typeExposure == uexDsl:
  #   result = 
  #     genAst(typeDecl, funcs):
  #           typeDecl          
  #           funcs
  # else:
  result = 
    genAst(typeDecl, props, funcs):
        typeDecl
        props
        funcs
  

  result.add genInterfaceConverers(typeDef)

func genImportCFunc*(typeDef : UEType, funField : UEField) : NimNode = 
  let formalParams = genFormalParamsInFunctionSignature(typeDef, funField, "obj")
  var pragmas = nnkPragma.newTree(
          nnkExprColonExpr.newTree(
            ident("importcpp"),
            newStrLitNode("$1_(@)")#Import the cpp func. Not sure if the value will work across all the signature combination
          ),
          nnkExprColonExpr.newTree(
            ident("header"),
            newStrLitNode("UEGenBindings.h")
          )
        )
  result = nnkProcDef.newTree([
              identPublic funField.getGenFuncName(), 
              newEmptyNode(), newEmptyNode(), 
              formalParams, 
              pragmas, newEmptyNode(), newEmptyNode()
            ])

  if  funField.metadata.any(x=>x.name=="Comment"): 
    result = newStmtList(result, newStrLitNode("##"&funField.metadata["Comment"].get()))

proc genDelType*(delType:UEType, exposure:UEExposure) : NimNode = 
  #NOTE delegates are always passed around as reference
  #adds the delegate to the global list of available delegates so we can lookup it when emitting the UCLass
  addDelegateToAvailableList(delType)
  let typeName = ident delType.name
   
  let delBaseType = 
    case delType.delKind 
    of uedelDynScriptDelegate: ident "FScriptDelegate"
    of uedelMulticastDynScriptDelegate: ident "FMulticastScriptDelegate"
  let broadcastFnName = 
    case delType.delKind 
    of uedelDynScriptDelegate: "execute"
    of uedelMulticastDynScriptDelegate: "broadcast"



  let typ = 
    if exposure == uexImport:
      genAst(typeName, delBaseType):
        type
          typeName {. inject, importcpp, header:"UEGenBindings.h".} = object of delBaseType
    else:
      genAst(typeName, delBaseType):
        type
          typeName {. inject, exportcpp.} = object of delBaseType


  let broadcastFunType = UEField(name:broadcastFnName, kind:uefFunction, signature: delType.fields)
  let funcNode = 
    if exposure == uexImport: genImportCFunc(delType, broadcastFunType)
    else: genFunc(delType, broadcastFunType).impl

  result = nnkStmtList.newTree(typ, funcNode)



func getFieldIdent*(prop:UEField) : NimNode = 
  let fieldName = ueNameToNimName(toLower($prop.name[0])&prop.name.substr(1)).nimToCppConflictsFreeName()
  identPublic fieldName

func getFieldIdentWithPCH*(typeDef: UEType, prop:UEField, isImportCpp: bool = false) : NimNode =  
  let fieldName = ueNameToNimName(toLower($prop.name[0])&prop.name.substr(1)).nimToCppConflictsFreeName()    
  if typeDef.isInPCH and isImportCpp:           
    nnkPragmaExpr.newTree(
      identPublic fieldName,
      nnkPragma.newTree(
        nnkExprColonExpr.newTree(ident "importcpp", newStrLitNode(prop.name))))                                    
  else:
    getFieldIdent(prop)
#TODO rename this dont use single letter variables
#TODO REFACTOR THIS. This is not simmetric at all. Either we split everything by it's type exposure or we dont split at all
#The padding function also add noise here. 
func genUStructTypeDef*(typeDef: UEType,  rule : UERule = uerNone, typeExposure:UEExposure) : NimNode = 
  let suffix = "_"
  let typeName = 
    case typeExposure: 
    of uexDsl: identWithInjectPublic typeDef.name
    of uexImport: 
      nnkPragmaExpr.newTree([
        nnkPostfix.newTree([ident "*", ident typeDef.name]),
        nnkPragma.newTree(
          ident "inject",
          nnkExprColonExpr.newTree(ident "importcpp", newStrLitNode("$1" & suffix)),
          nnkExprColonExpr.newTree(ident "header", newStrLitNode("UEGenBindings.h"))
        )
      ])
    of uexExport: #Note this path is not used. TODO Remove
      let importExportPragma =
        if typeDef.isInPCH:
          ident "importcpp"
        else:
          nnkExprColonExpr.newTree(ident "exportcpp", newStrLitNode("$1" & suffix))
          
      nnkPragmaExpr.newTree([
        nnkPostfix.newTree([ident "*", ident typeDef.name]),
        nnkPragma.newTree(
          ident "inject",
          importExportPragma
        )
      ])

    
  let fields =
    case typeExposure:
    of uexDsl, uexImport:
      typeDef.fields
        .map(prop => 
          nnkIdentDefs.newTree(
            getFieldIdentWithPCH(typeDef, prop),
            prop.getTypeNodeFromUProp(isVarContext=false),             
            newEmptyNode()))
        .foldl(a.add b, nnkRecList.newTree)
    of uexExport: 
      if typeDef.isInPCH:
         typeDef.fields
          .map(prop => 
            nnkIdentDefs.newTree(
              getFieldIdentWithPCH(typeDef, prop),
              prop.getTypeNodeFromUProp(isVarContext=false),             
              newEmptyNode()))
          .foldl(a.add b, nnkRecList.newTree)
      else:
        var fields = nnkRecList.newTree()
        var size, offset, padId: int
        for prop in typeDef.fields:
          let fieldName = ueNameToNimName(toLower($prop.name[0])&prop.name.substr(1)).nimToCppConflictsFreeName()    
          var propIden = nnkIdentDefs.newTree(
            nnkPragmaExpr.newTree(
              ident fieldName,
              nnkPragma.newTree(
                ident "inject",
                nnkExprColonExpr.newTree(ident "importcpp", newStrLitNode(prop.name)),
              )
            ), 
            prop.getTypeNodeFromUProp(isVarContext=false), 
            newEmptyNode())

          let offsetDelta = prop.offset - offset
          if offsetDelta > 0:
            fields.add nnkIdentDefs.newTree(ident("pad_" & $padId), nnkBracketExpr.newTree(ident "array", newIntLitNode(offsetDelta), ident "byte"), newEmptyNode())
            inc padId
            offset += offsetDelta
            size += offsetDelta

          fields.add propIden
          size = offset + prop.size
          offset += prop.size

        if size < typeDef.size:
          fields.add nnkIdentDefs.newTree(ident("pad_" & $padId), nnkBracketExpr.newTree(ident "array", newIntLitNode(typeDef.size - size), ident "byte"), newEmptyNode())
        fields

  if typeDef.superStruct == "":
    result = genAst(typeName, fields):
          type typeName = object
    result[0][^1] = nnkObjectTy.newTree([newEmptyNode(), newEmptyNode(), fields])

  else:
    let superStruct = ident typeDef.superStruct
    result = genAst(typeName, superStruct, fields):
          type typeName = object of superStruct
    result[0][^1][^1] = fields

  

  if typeExposure == uexExport:  
    result = newEmptyNode() #exportc since Nim 2.0 exports the type so nothing to do here. 


func genUEnumTypeDef*(typeDef:UEType, typeExposure:UEExposure) : NimNode = 
  let typeName = ident(typeDef.name)
  let fields = typeDef.fields
            .map(f => ident f.name)
            .foldl(a.add b, nnkEnumTy.newTree)
  fields.insert(0, newEmptyNode()) #required empty node in enums

  result= genAst(typeName, fields):
        type typeName* {.inject, size:sizeof(uint8), pure.} = enum     
          fields

  result[0][^1] = fields #replaces enum 


  if typeExposure == uexExport: 
    result = newEmptyNode() #exportc since Nim 2.0 exports the type so nothing to do here. 

func genPropsAsRecList(ueType: UEType, rule: UERule = uerNone) : NimNode =
  var recList = nnkRecList.newTree()
  var size, offset, padId: int
  for prop in ueType.fields:
    let fieldName = ueNameToNimName(toLower($prop.name[0])&prop.name.substr(1)).nimToCppConflictsFreeName()    
    let propIden = 
      if ueType.isInPCH:
        nnkIdentDefs.newTree(
          nnkPragmaExpr.newTree(
            ident fieldName,
            nnkPragma.newTree(
              nnkExprColonExpr.newTree(ident "importcpp", newStrLitNode(prop.name)),
            )
          ), 
          prop.getTypeNodeFromUProp(isVarContext=false), 
          newEmptyNode())
        else: 
          nnkIdentDefs.newTree(getFieldIdent(prop), prop.getTypeNodeFromUProp(isVarContext=false), newEmptyNode())
 

    let offsetDelta = prop.offset - offset
    if offsetDelta > 0 and not ueType.isInPCH:
      recList.add nnkIdentDefs.newTree(ident("pad_" & $padId), nnkBracketExpr.newTree(ident "array", newIntLitNode(offsetDelta), ident "byte"), newEmptyNode())
      inc padId
      offset += offsetDelta
      size += offsetDelta

    recList.add propIden
    size = offset + prop.size
    offset += prop.size

  if size < ueType.size and not ueType.isInPCH:
    recList.add nnkIdentDefs.newTree(ident("pad_" & $padId), nnkBracketExpr.newTree(ident "array", newIntLitNode(ueType.size - size), ident "byte"), newEmptyNode())
  recList

func genUStructTypeDefBinding*(ueType: UEType, rule: UERule = uerNone): NimNode =  
  let recList = genPropsAsRecList(ueType, rule)
  let importExportPragma =
    if ueType.isInPCH:
      ident "importcpp"
    else:
      nnkExprColonExpr.newTree(ident "exportcpp", newStrLitNode("$1" & "_"))

  nnkTypeDef.newTree(
    nnkPragmaExpr.newTree([
      nnkPostfix.newTree([ident "*", ident ueType.name.nimToCppConflictsFreeName()]),
      nnkPragma.newTree(
        ident "inject",        
        importExportPragma
      )
    ]),
    newEmptyNode(),
    nnkObjectTy.newTree(
      newEmptyNode(), newEmptyNode(), recList
    )
  )


proc genTypeDecl*(typeDef : UEType, rule : UERule = uerNone, typeExposure = uexDsl) : NimNode = 
  case typeDef.kind:
    of uetClass:
      genUClassTypeDef(typeDef, rule, typeExposure)
    of uetStruct:
      genUStructTypeDef(typeDef, rule, typeExposure)
    of uetEnum:
      genUEnumTypeDef(typeDef, typeExposure)
    of uetDelegate:
      genDelType(typeDef, typeExposure)
    of uetInterface:
      newEmptyNode() #Not gen interfaces for now

macro genType*(typeDef : static UEType) : untyped = genTypeDecl(typeDef)
proc ueBindImpl(clsName : string, fn: NimNode) : NimNode = 
  let clsFieldMb = 
    if clsName!="": some makeFieldAsUProp("obj", clsName, clsName) 
    else: none[UEField]()

  var (fnField, firstParam) = uFuncFieldFromNimNode(fn, clsFieldMb, clsName, @[])
  if clsFieldMb.isSome:
    fnField.fnFlags = FUNC_Static
  #Generates a fake class form the classField. 
  let typeDefFn = makeUEClass(firstParam.uePropType, parent="", CLASS_None, @[fnField])
  result = genFunc(typeDefFn, fnField).impl

macro uebind*(fn:untyped) : untyped = ueBindImpl("", fn)
macro uebindStatic*(clsName : static string = "", fn:untyped) : untyped = ueBindImpl(clsName, fn)

macro ueBindProp*(cls:typedesc, propName:untyped, typ:typedesc) = 
  let ueType = UEType(name: cls.strVal().removeLastLettersIfPtr(), kind: uetClass) #notice it only binds uclasses. Struct cant be bound like this
  let ueProp = UEField(name: propName.strVal(), uePropType: typ.strVal(), kind: uefProp)
  genProp(ueType, ueProp)
