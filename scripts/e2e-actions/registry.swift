// fz-registry: asks Frenzy's own action registry (HaloCore + HaloConverters, built from source by e2e-actions.sh with
// -enable-testing) which actions exist and which accept a file. Pure lookups: nothing here converts anything.
//
//   fz-registry ENGINE list               id <TAB> category <TAB> each|combined:N <TAB> title
//   fz-registry ENGINE match FILE...      path <TAB> type <TAB> video:0|1 <TAB> id,id,...   (actions that take that one file)
//   fz-registry ENGINE group FILE...      id,id,...   (actions that take all the files together)
//   fz-registry ENGINE waiting            ids kept out of the registry until the safe video plan
//
// ENGINE is 1 when the app under test bundles the media engine (Apple silicon), else 0: the same switch the app uses.

import Foundation
import UniformTypeIdentifiers
import HaloCore
@testable import HaloConverters

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("usage: fz-registry 0|1 list|match|group|waiting [FILE...]")
    exit(64)
}
let engine = args[0] == "1"
let actions = DefaultActions.all(engine: engine)
let files = args.dropFirst(2).map { URL(fileURLWithPath: $0) }

func isVideo(_ type: UTType) -> Bool {
    type.conforms(to: .movie) || type.conforms(to: .video)
}

switch args[1] {
case "list":
    for a in actions {
        let card: String
        switch a.cardinality {
        case .each: card = "each"
        case .combined(let min): card = "combined:\(min)"
        }
        print("\(a.id.rawValue)\t\(a.category.rawValue)\t\(card)\t\(a.title)")
    }
case "match":
    for url in files {
        guard let input = InputFile(url: url) else {
            print("\(url.path)\t-\tvideo:0\t")
            continue
        }
        let ids = actions.filter { $0.accepts([input]) }.map(\.id.rawValue)
        print("\(url.path)\t\(input.type.identifier)\tvideo:\(isVideo(input.type) ? 1 : 0)\t\(ids.isEmpty ? "-" : ids.joined(separator: ","))")
    }
case "group":
    let inputs = files.compactMap { InputFile(url: $0) }
    guard inputs.count == files.count else { print("-"); exit(0) }
    let ids = actions.filter { $0.accepts(inputs) }.map(\.id.rawValue)
    print(ids.isEmpty ? "-" : ids.joined(separator: ","))
case "videoout":
    // Video out of foreign formats: x264 / x265 in the engine (CPU), registered whenever the engine is.
    for a in EngineActions.videoOut { print(a.id.rawValue) }
default:
    print("unknown command \(args[1])")
    exit(64)
}
