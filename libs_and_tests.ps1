Import-Module Psake

$dotnet = (Get-Command dotnet.exe).Path

#region Define file sets

Task query_projectstructure -description "Collect infomation about the project structure which is useful for other build tasks"  {

    # All soures are under /src
    $script:sourceDirectoryName = Join-Path $PSScriptRoot src -Resolve
    # All tests are under /test
    $script:testDirectoryName = Join-Path $PSScriptRoot test -Resolve

    # Get file items for all projects
    $script:projectJsonItems = Get-ChildItem -Path $PSScriptRoot -Include "project.json"  -File -Recurse
    # Subset of src projects
    $script:testProjectJsonItems = $script:projectJsonItems | Where-Object { $_.DirectoryName.StartsWith($script:testDirectoryName) }
    # Subset of tets projects
    $script:sourceProjectJsonItems = $script:projectJsonItems | Where-Object { $_.DirectoryName.StartsWith($script:sourceDirectoryName) }

    # test results are stored in a seperate directory
    $script:testResultsDirectory = New-Item -Path $PSScriptRoot\.testresults -ItemType Directory -ErrorAction SilentlyContinue
}

Task clean_projectstructure -description "Remove temporary build files" {
    
    # Remove temporary test result directory
    Remove-Item $script:testResultsDirectory -Recurse -Force -ErrorAction SilentlyContinue

} -depends query_projectstructure

#endregion 

#region Build targets for NuGet dependencies 

Task clean_dependencies -description "Remove nuget package cache from current users home" {
    
    # dotnet cli utility uses the users package cache only. 
    # a project local nuget cache can be enforced but is not necessary by default.
    # This differs from nuget.exe's behavior which uses by default project local packages directories
    # see also: https://docs.microsoft.com/de-de/dotnet/articles/core/tools/dotnet-restore

    Remove-Item (Join-Path $HOME .nuget\packages) -Force -Recurse -ErrorAction SilentlyContinue
}

Task restore_dependencies -description "Restore nuget dependencies" {
    
    Push-Location $PSScriptRoot
    try {
        
        # Calling dot net restore in root directory should be enough. 
        & $dotnet restore

    } finally {
        Pop-Location
    }
}

Task report_dependencies -description "Print a list of all nuget dependencies. This is useful for mainline clearing." {
    
    # For Mainline clearing a complete set of nuget packages has to be retrieved.
    # These are taken from the 'dependencies' section of all src project.jsons

    $nugetDependencies = $script:sourceProjectJsonItems | Get-Content -Raw | ConvertFrom-Json | ForEach-Object {
        $_.dependencies.PSObject.Properties | ForEach-Object {
            if($_.Value -is [string]) {
                [pscustomobject]@{
                    Id = $_.Name
                    Version = $_.Value
                }
            } else {
                [pscustomobject]@{
                    Id = $_.Name
                    Version = $_.Value.Version
                }
            }
        }
    }
    $nugetDependencies | Group-Object Id | Select-Object Name,Group

} -depends query_projectstructure

#endregion

#region Build targets for .Net Assemblies

Task build_assemblies -description "Compile all projects into .Net assemblies" {

    Push-Location $PSScriptRoot
    try {

        & $dotnet build "**\project.json"

    } finally {
        Pop-Location
    }
}

Task clean_assemblies -description "Remove all the usual build directories under the project root" {
    
    $script:projectJsonItems | ForEach-Object {

        # just remove the usual oputput directories instead of spefific files or file extsnsions.
        # This included Cosumentatin files, config files or other artefacts which are copied 
        # to the build directory

        Remove-Item -Path (Join-Path $_.Directory bin) -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $_.Directory obj) -Recurse -ErrorAction SilentlyContinue
    }

} -depends query_projectstructure

Task test_assemblies -description "Run the unit test under 'test'. Output is written to .testresults directory" {
    
    $script:testProjectJsonItems | ForEach-Object {

        Push-Location $_.Directory
        try {
            
            $testResultFileName = Join-Path $script:testResultsDirectory "$($_.Directory.BaseName).xml"

            # Check if nunit or xunit is used as a test runner. They use diffrent parameters
            # for test result file path specification

            $testProjectJsonContent = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if($testProjectJsonContent.testRunner -eq "xunit") {

                # the projects directory name is taken as the name of the test result file.
                &  $dotnet test -xml $testResultFileName

            } else {
                # NUnit: 
                # the projects directory name is taken as the name of the test result file.
                &  $dotnet test -result:$testResultFileName
            }

        } finally {
            Pop-Location
        }
    }

} -depends query_projectstructure

#endregion

Task clean -description "The project tree is clean: all artifacts created by the development tool chain are removed"  -depends clean_assemblies
Task restore -description "External dependencies are restored.The project is ready to be built." -depends restore_dependencies
Task build -description "The project is built: all artifacts created by the development tool chain are created" -depends restore,build_assemblies
Task test -description "The project is tested: all automated tests of the project are run" -depends build,test_assemblies

Task default -depends clean,restore,test
