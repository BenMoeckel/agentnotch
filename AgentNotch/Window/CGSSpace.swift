import Foundation

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
func CGSDefaultConnection() -> CGSConnectionID

@_silgen_name("CGSSpaceCreate")
func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: CFDictionary?) -> CGSSpaceID

@_silgen_name("CGSSpaceDestroy")
func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)

@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

@_silgen_name("CGSShowSpaces")
func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)

@_silgen_name("CGSHideSpaces")
func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: CFArray)
