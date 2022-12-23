#Host guest (which will be renamed as plugin) and the game will be compiled from this file. Nue will use functions from here. 
#We may extrac the compilation option to another file since there are a lot of platforms. 

import std / [ options, os, osproc, parseopt, sequtils, strformat, strutils, sugar, tables, times ]
import buildscripts/[buildcommon, buildscripts, nimforueconfig]
import ../switches/switches
let config = getNimForUEConfig()


proc compileHost*() = 
  let buildFlags = @[buildSwitches].foldl(a & " " & b.join(" "), "")
  doAssert(execCmd(&"nim cpp {buildFlags} --cc:vcc --header:NimForUEFFI.h --debugger:native --threads --tlsEmulation:off --app:lib --d:host --nimcache:.nimcache/host src/hostnimforue/hostnimforue.nim") == 0)
  
  # copy header
  let ffiHeaderSrc = ".nimcache/host/NimForUEFFI.h"
  let ffiHeaderDest = "NimHeaders" / "NimForUEFFI.h"
  copyFile(ffiHeaderSrc, ffiHeaderDest)
  log("Copied " & ffiHeaderSrc & " to " & ffiHeaderDest)

  # copy lib
  let libDir = "./Binaries/nim"
  let libDirUE = libDir / "ue"
  createDir(libDirUE)

  let hostLibName = "hostnimforue"
  let baseFullLibName = getFullLibName(hostLibName)
  let fileFullSrc = libDir/baseFullLibName
  let fileFullDst = libDirUE/baseFullLibName

  try:
    copyFile(fileFullSrc, fileFullDst)
  except OSError as e:
    when defined windows: # This will fail on windows if the host dll is in use.
      quit("Error copying to " & fileFullDst & ". " & e.msg, QuitFailure)

  log("Copied " & fileFullSrc & " to " & fileFullDst)

  when defined windows:
    let weakSymbolsLib = hostLibName & ".lib"
    copyFile(libDir/weakSymbolsLib, libDirUE/weakSymbolsLib)
  elif defined macosx: #needed for dllimport in ubt mac only
    let dst = "/usr/local/lib" / baseFullLibName
    copyFile(fileFullSrc, dst)
    log("Copied " & fileFullSrc & " to " & dst)


proc compilePlugin*(extraSwitches:seq[string],  withDebug:bool) =
  generateFFIGenFile(config)
  let guestSwitches = @[
    "-d:BindingPrefix=.nimcache/gencppbindings/@m..@sunreal@sbindings@sexported@s",
    "-d:guest",
  ]
  let buildFlags = @[buildSwitches, targetSwitches(withDebug), ueincludes, uesymbols, pluginPlatformSwitches(withDebug), extraSwitches, guestSwitches].foldl(a & " " & b.join(" "), "")
  let compCmd = &"nim cpp {buildFlags} --app:lib --d:genffi -d:withPCH --nimcache:.nimcache/guest src/nimforue.nim"
  doAssert(execCmd(compCmd)==0)
  
  copyNimForUELibToUEDir("nimforue")


proc compileGame*(extraSwitches:seq[string], withDebug:bool) = 
  let gameSwitches = @[
    "-d:game",
    "-p:../../NimForUE/",
    "-p:src/game/",
    "-p:src/nimforue/",
    "-p:src/nimforue/game",
    "-p:src/nimforue/unreal",
    "-p:src/nimforue/unreal/bindings",
    "-d:BindingPrefix=.nimcache/gencppbindings/@m..@sunreal@sbindings@sexported@s"
    # "--include:../game/nueprelude"
  ]

  let gameFolder = NimGameDir

  let buildFlags = @[buildSwitches, targetSwitches(withDebug), ueincludes, uesymbols, gamePlatformSwitches(withDebug), gameSwitches, extraSwitches].foldl(a & " " & b.join(" "), "")
  let compCmd = &"nim cpp {buildFlags} --app:lib  -d:withPCH --nimcache:.nimcache/game {gameFolder}/game.nim"
  doAssert(execCmd(compCmd)==0)
  
  copyNimForUELibToUEDir("game")



proc compileGenerateBindings*() = 
  let buildFlags = @[buildSwitches, targetSwitches(false), pluginPlatformSwitches(false), ueincludes, uesymbols].foldl(a & " " & b.join(" "), "")
  doAssert(execCmd(&"nim  cpp {buildFlags}  --noMain --compileOnly --header:UEGenBindings.h  --nimcache:.nimcache/gencppbindings src/nimforue/codegen/maingencppbindings.nim") == 0)
  let ueGenBindingsPath =  config.nimHeadersDir / "UEGenBindings.h"
  copyFile("./.nimcache/gencppbindings/UEGenBindings.h", ueGenBindingsPath)
  #It still generates NimMain in the header. So we need to get rid of it:
  let nimMain = "N_CDECL(void, NimMain)(void);"
  writeFile(ueGenBindingsPath, readFile(ueGenBindingsPath).replace(nimMain, ""))
