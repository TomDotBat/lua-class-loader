--[[-----------------------------------------------------------------------------
    Copyright 2021 Thomas (Tom.bat) O'Sullivan

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.

    You may obtain a copy of the License at:
        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

    See the License for the specific language governing permissions and
    limitations under the License.
-------------------------------------------------------------------------------]]

local ClassLoader = {}

local packages = {}
local currentPackage, currentFile
local baseDirectory

local realmReplacements = {
    ["cl_"] = "",
    ["sv_"] = "",
    ["sh_"] = ""
}

local function packageNameToObjectName(packageName)
    return packageName
        :match("[^.]+$") --Get the last item from the package name
        :gsub("%a%a_", realmReplacements) --Strip realm prefixes
        :gsub("^%l", string.upper) --Capitalise first letter
        :gsub("_%l", string.upper) --Capitalise every letter with an underscore before
        :gsub("%_", "") --Remove all underscores
end

local function stripLastItemFromPackageName(packageName)
    return packageName:sub(1,
        -(#packageName:match("[^.]+$") --Get the length of the last item from the location
            + 2))
end

do
    local function locationAsAbsolute(location)
        return location:find(".", 1, true)
            and location
            or currentPackage.__name .. "." .. location
    end

    local function packageNameAsDirectoryPath(packageName)
        return baseDirectory
            .. packageName:gsub("%.", "/")
            .. "/"
    end

    local function importPackage(packageName)
        if not packages[packageName] then
            ClassLoader.LoadDirectory(packageNameAsDirectoryPath(packageName), true)
        end

        local objects = {}

        for objectName, object in pairs(packages[packageName]) do
            if objectName:sub(2) ~= "__" then
                currentFile[objectName] = object
                table.insert(objects, object)
            end
        end

        return objects
    end

    local function addObjectToCurrentFile(objectPackage, objectName)
        if not objectPackage[objectName] then
            objectPackage[objectName] = {}
        end

        local object = objectPackage[objectName]

        if currentFile then
            currentFile[objectName] = object
        end

        return object
    end

    function ClassLoader.ImportObject(location)
        assert(isstring(location), "Objects may only be imported by their location")

        location = locationAsAbsolute(location)

        local packageName = stripLastItemFromPackageName(location)

        if location:sub(-1) == "*" then
            return importPackage(packageName)
        end

        return addObjectToCurrentFile(ClassLoader.GetPackage(packageName),
            packageNameToObjectName(location))
    end
end

do
    local function getCurrentFileObject()
        return currentPackage[currentFile.__objectName]
    end

    local function instantiateClass(class)
        assert(class, "The class constructor must be called with a colon")
        return setmetatable({}, class)
    end

    local baseEnvironment = {
        Import = ClassLoader.ImportObject,
        Class = function()
            local class = getCurrentFileObject()
            class.__type = "Class"
            class.__isClass = true
            class.__index = class

            class.New = instantiateClass
            class.Extends = ClassLoader.ExtendObject

            return class
        end,
        Singleton = function()
            local singleton = getCurrentFileObject()
            singleton.__type = "Singleton"
            singleton.__isSingleton = true

            return singleton
        end,
        Enum = function()
            local enum = getCurrentFileObject()
            enum.__type = "Enum"
            enum.__isEnum = true

            return enum
        end
    }

    baseEnvironment.__index = baseEnvironment

    function ClassLoader.GetPackage(packageName)
        assert(isstring(packageName), "The package location must be provided as a string")

        if packages[packageName] then
            return packages[packageName]
        end

        local package = {
            __name = packageName,
            __type = "Package",
            __isPackage = true,
            _G = _G
        }

        package.__index = package
        setmetatable(package, baseEnvironment)

        packages[packageName] = package
        return package
    end
end

function ClassLoader.ExtendObject(class, super)
    assert(istable(class), "The class being extended must be a table")

    if not istable(super) then
        assert(isstring(super), "Classes may only be extended by objects or names")

        super = ClassLoader.ImportObject(super)
        assert(istable(super), "The super class name didn't resolve to an object")
    end

    class.__super = super
    setmetatable(class, super)

    return class
end

do
    local function filePathToObjectPackageName(filePath)
        return filePath
            :sub(#baseDirectory + 1) --Strip the base directory
            :sub(1, (filePath:sub(-4) == ".lua") and -5 or -1) --Strip the file extension if it's present
            :gsub("%/", ".") --Replace all forward slashes with dots
    end

    local function filePathToObjectPackageAndName(filePath)
        local location = filePathToObjectPackageName(filePath)

        return stripLastItemFromPackageName(location),
            packageNameToObjectName(location)
    end

    local function createFileEnvironment(filePath, packageName, objectName)
        currentFile = setmetatable({
            __objectName = objectName
        }, currentPackage)

        return currentFile
    end

    local function registerObject(packageName, objectName, object)
        assert(istable(object), "Invalid object returned by: " .. packageName  .. "." .. objectName)

        object.__name = objectName
        object.__package = packageName

        if object.Extends == ClassLoader.ExtendObject then
            object.Extends = nil
        end

        currentPackage[objectName] = object
    end

    local function preparePackage(directory, files)
        local packageName = filePathToObjectPackageName(directory):sub(1, -2)
        local package = ClassLoader.GetPackage(packageName)

        for _, fileName in ipairs(files) do
            local objectName = packageNameToObjectName(fileName:sub(1, -5))
            package[objectName] = package[objectName] or {}
        end

        return package
    end

    local function loadFile(filePath)
        local packageName, objectName = filePathToObjectPackageAndName(filePath)

        local file = CompileFile(filePath)
        debug.setfenv(file, createFileEnvironment(filePath, packageName, objectName))

        registerObject(packageName, objectName, file())
    end

    local function loadFiles(directory, files)
        for i, fileName in ipairs(files) do
            if fileName:sub(-4) == ".lua" then
                local filePath = directory .. fileName

                if CLIENT then
                    loadFile(filePath)
                else
                    if fileName:StartWith("cl_") then
                        AddCSLuaFile(filePath)
                    elseif fileName:StartWith("sh_") then
                        AddCSLuaFile(filePath)
                        loadFile(filePath)
                    else
                        loadFile(filePath)
                    end
                end
            end
        end
    end

    local function loadDirectory(directory, importMode)
        assert(isstring(directory), "The directory to load must be provided as a string")

        local files, directories = file.Find(directory .. "*", "LUA")

        if importMode then
            preparePackage(directory, files)
            return
        else
            currentPackage = preparePackage(directory, files)
        end

        loadFiles(directory, files)

        for i, directoryName in ipairs(directories) do
            loadDirectory(directory .. directoryName .. "/")
        end
    end

    ClassLoader.LoadDirectory = loadDirectory
end

do
    local function cleanUpPackages()
        for packageName, package in pairs(packages) do
            setmetatable(package, nil)

            if not next(package, "__name") then --Name is the last default key
                packages[packageName] = nil
            end
        end
    end

    local function callEntryPoint(classLocation)
        local startClass = ClassLoader.ImportObject(classLocation)

        assert(startClass.__type, "The start class couldn't be found at: " .. classLocation)
        assert(startClass.__isSingleton, "The start class may only be a singleton")
        assert(startClass.Main, "The start class doesn't have a main method")

        startClass:Main()
    end

    function ClassLoader.Bootstrap(directory, startClassLocation)
        assert(isstring(directory), "The base directory must be provided as a string")
        assert(isstring(startClassLocation), "The start class location must be provided as a string")

        baseDirectory = directory:sub(-1) == "/" and directory or directory .. "/"

        ClassLoader.LoadDirectory(baseDirectory)

        cleanUpPackages()
        callEntryPoint(startClassLocation)

        currentPackage, currentFile, baseEnvironment = nil, nil, nil
        collectgarbage()
    end
end

return ClassLoader