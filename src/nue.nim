# tooling for NimForUE

import std / [os, osproc, parseopt, tables, strformat, strutils, times]
#import buildscripts / [buildscripts, nimforueconfig]

type Task = object
  name: string
  description: string
  routine: proc(options: Table[string, string]) {.nimcall.}

var tasks: seq[Task] = @[]

template task(taskName: untyped, desc: string, body: untyped): untyped =
  proc `taskName`(options: Table[string, string]) {.nimcall.} =
    echo ">>>> Task: ", astToStr(taskName), " <<<<"
    body
  tasks.add(Task(name: astToStr(taskName), description: desc, routine: `taskName`))

let watchInterval = 500

task watch, "Monitors the components folder for changes to recompile.":
  proc ctrlc() {.noconv.} =
    echo "Ending watcher"
    quit()

  setControlCHook(ctrlc)

  let srcDir = getCurrentDir() / "src/nimforue/"
  echo &"Monitoring components for changes in \"{srcDir}\".  Ctrl+C to stop"
  var lastTimes = newTable[string, Time]()
  for path in walkDirRec(srcDir ):
    if not path.endsWith(".nim"):
      continue
    lastTimes[path] = getLastModificationTime(path)

  while true:
    for path in walkDirRec(srcDir ):
      if not path.endsWith(".nim"):
        continue
      var lastTime = getLastModificationTime(path)
      if lastTime > lastTimes[path]:
        lastTimes[path] = lastTime
        echo &"-- Recompiling {path} --"
        when defined windows:
          let p = startProcess("nimble", getCurrentDir(), ["nimforue"])
          for line in p.lines:
            echo line
          p.close
        elif defined macosx:
          # startProcess is crashing on macosx for some reason
          let (output, _) = execCmdEx("nimble nimforue")
          echo output
        echo &"-- Finished Recompiling {path} --"

    sleep watchInterval

var options: Table[string, string]
var params = commandLineParams().join(" ")
if params.len == 0:
  echo "nue: NimForUE tool"

var p = initOptParser()
for kind, key, val in p.getopt():
  case kind
  of cmdEnd: doAssert(false) # cannot happen with getopt
  of cmdShortOption, cmdLongOption:
    case key:
    of "h", "help":
      echo "Usage, Commands and Options for nue"
      quit()
    else:
      options[key] = val
  of cmdArgument:
    case key:
    of "configure":
      echo "configure global settings for nue"
    of "watch":
      watch(options)
    of "host":
      echo "compile the host dll"
    of "guest":
      echo "compile the guest dll"
    of "init":
      echo "initialize the NimForUE plugin for your Unreal project"
    else:
      echo &"Unknown argument for nue {key}"


#[
template callTask(name: untyped) =
    ## Invokes the nimble task with the given name
    exec "nimble " & astToStr(name)

task nimforue, "Builds the main lib. The one that makes sense to hot reload.":
    generateFFIGenFile()
    exec("nim cpp --app:lib --d:genffi -d:withue src/nimforue.nim")
    exec("nim c -d:release --run src/buildscripts/copyLib.nim")

task watch, "Watchs the main lib and rebuilds it when something changes.":
    #There is something going on with the hotreloeader, it rebuilds even if the file doesnt change
    exec("""watchexec -w ./src/nimforue -r nimble "nimforue"""")
  

task host, "Builds the library that's hooked to unreal":
    exec("nim cpp --app:lib --d:host src/hostnimforue/hostnimforue.nim")
    
    #TODO using a custom cache dir would be better
    let cacheFolderName = if getNimForUEConfig().targetConfiguration == Shipping: "hostnimforue_r" else: "hostnimforue_d" 
    copyFileFromNimCachetoLib("NimForUEFFI.h", "./NimHeaders/NimForUEFFI.h", "../"&cacheFolderName) #temp hack to copy the header. 
    copyLibToUE4("hostnimforue")
    when defined macosx:
        #needed for dllimport in ubt mac only
        let src = "./Binaries/nim/libhostnimforue.dylib"
        let dst = "/usr/local/lib/libhostnimforue.dylib"
        cpFile src, dst
        echo "Copied " & src & " to " & dst
    generateUBTScriptFile() #move to generateProject whe it exists
 
task buildlibs, "Builds the sdk and the ffi which generates the headers":
    callTask nimforue
    callTask host


task clean, "deletes all files generated by the project":
    exec("rm -rf ./Binaries/nim/")
    exec("rm /usr/local/lib/libhostnimforue.dylib")
    exec("rm NimForUE.mac.json")
    ]#