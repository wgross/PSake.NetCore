Import-Module Pester

$dotnet = (Get-Command dotnet.exe).Path

#region Define file sets

Task query_projectstructre -description "Collect infomation about the project structure which is useful for other build tasks"  {

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

Task clean_projectstruture -description "Remove temporary build files" {
    
    # Remove temporary test result directory
    Remove-Item $script:testResultsDirectory -Recurse -Force -ErrorAction SilentlyContinue

} -depends query_projectstructre

#endregion 

#region Build targets for NuGet dependencies 

Task clean_nuget -description "Remove nuget package cache from current users home" {
    
    # dotnet cli utility uses the users package cache only. 
    # a project local nuget cache can be enforced but is not necessary by default.
    # This differs from nuget.exe's behavior which uses by default project local packages directories
    # see also: https://docs.microsoft.com/de-de/dotnet/articles/core/tools/dotnet-restore

    Remove-Item (Join-Path $HOME .nuget\packages) -Force -Recurse -ErrorAction SilentlyContinue
}

Task restore_nuget -description "Restore nuget dependencies" {
    
    Push-Location $PSScriptRoot
    try {
        
        # Calling dot net restore in root directory should be enough. 
        & $dotnet restore

    } finally {
        Pop-Location
    }
}

Task report_nuget -description "Print a list of all nuget dependencies. This is useful for mainline clearing." {
    
    # For Mainline clearing a complete set of nuget packages has to be retrieved.
    # These are taken from the 'dependensies' section of all src project.jsons

    $nugetDependecies = $script:sourceProjectJsonItems | Get-Content -Raw | ConvertFrom-Json | ForEach-Object {
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
    $nugetDependecies | Group-Object Id | Select-Object Name,Group

} -depends query_projectstructre

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

Task clean_assemblies -description "Remove all assemblies (Dll and Exe) under the project root" {
    
    $script:projectJsonItems | ForEach-Object {

        Get-ChildItem -Path $_.Directory -Include "*.dll","*.exe" -File -Recurse | Remove-Item
    }

} -depends query_projectstructre

Task test_assemblies -description "Run the unit test under 'test'. Output is written to .testresults directory" {
    
    $script:testProjectJsonItems | ForEach-Object {

        Push-Location $_.Directory
        try {
            
            # the projects directory name is taken as the name of the test result file.
            &  $dotnet test -xml "$script:testResultsDirectory\$($_.Directory.BaseName).xml"

        } finally {
            Pop-Location
        }
    }

} -depends query_projectstructre

#endregion

Task clean -description "The project tree is clean: all artifacts created by the development tool chain are removed"  -depends clean_assemblies
Task restore -description "External dependencies are restored.The project is ready to be built." -depends restore_nuget
Task build -description "The project is built: all artifacts created by the development tool chain are created" -depends restore,build_assemblies
Task test -description "The project is tested: all automated tests of the project are run" -depends build,test_assemblies

Task default -depends clean,restore,test
