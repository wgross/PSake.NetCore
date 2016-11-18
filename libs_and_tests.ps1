Import-Module Psake

$script:dotnet = (Get-Command dotnet.exe).Path
$script:nuget = (Get-Command nuget.exe).Path

#region Define file sets

Task query_workspace -description "Collect infomation about the workspace structure which is useful for other build tasks"  {

    $script:projectItems = @{}
    $script:projectItems.all = @()

    $globalJsonContent = Get-Content $PSScriptRoot\global.json -Raw | ConvertFrom-Json 
    $globalJsonContent.projects | ForEach-Object {
        $projectSubDir = $_ 
        $script:projectItems.Add($projectSubDir,(Get-ChildItem -Path (Join-Path $PSScriptRoot $projectSubDir)  -Include "project.json" -File -Recurse))
        $script:projectItems[$projectSubDir] | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host "found projects in $projectSubDir : $_" }
        $script:projectItems.all += $script:projectItems[$projectSubDir]
    } 
}

#endregion 

#region Tasks for NuGet dependencies 

Task clean_dependencies -description "Remove nuget package cache from current users home" {
    
    # dotnet cli utility uses the users package cache only. 
    # a project local nuget cache can be enforced but is not necessary by default.
    # This differs from nuget.exe's behavior which uses by default project local packages directories
    # see also: https://docs.microsoft.com/de-de/dotnet/articles/core/tools/dotnet-restore

    Remove-Item (Join-Path $HOME .nuget\packages) -Force -Recurse -ErrorAction SilentlyContinue
}

Task build_dependencies -description "Restore nuget dependencies for all projects" {
    
    Push-Location $PSScriptRoot
    try {
        
        # Calling dot net restore in root directory should be enough. 
        & $script:dotnet restore

    } finally {
        Pop-Location
    }
}

Task query_dependencies -description "Print a list of all nuget dependencies. This is useful for OSS licence clearing" {
    
    # For Mainline clearing a complete set of nuget packages has to be retrieved.
    # These are taken from the 'dependencies' section of all src project.jsons
    # !! framework specific dependencies are not queried !!

    $nugetDependencies = $script:projectItems.src | Get-Content -Raw | ConvertFrom-Json | ForEach-Object {
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

} -depends query_workspace

#endregion

#region Tasks for .Net Assemblies

Task init_assemblies {
    
    # test results are stored in a separate directory
    if(Test-Path $PSScriptRoot\.testresults) {
        $script:testResultsDirectory = Get-Item -Path $PSScriptRoot\.testresults
    } else {   
        $script:testResultsDirectory = New-Item -Path $PSScriptRoot\.testresults -ItemType Directory
    }

}

Task clean_assemblies -description "Removes the assembles built by 'build_assembly' task" {
    
    $script:projectItems.all | ForEach-Object {

        # just remove the usual oputput directories instead of spefific files or file extensions.
        # This includes automatically assemblies, config files or other artefacts which are copied 
        # to the build directory

        Remove-Item -Path (Join-Path $_.Directory bin) -Recurse -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $_.Directory obj) -Recurse -ErrorAction SilentlyContinue
    }

} -depends query_workspace

Task build_assemblies -description "Compile all projects into .Net assemblies" {

    Push-Location $PSScriptRoot
    try {

        & $script:dotnet build "**\project.json"

    } finally {
        Pop-Location
    }
}

Task test_assemblies -description "Run the unit test under 'test'. Output is written to .testresults directory" {
    
    $script:test_assemblies_results = [System.Collections.ArrayList]::new()
    $script:projectItems.test | ForEach-Object {

        Push-Location $_.Directory
        try {
          
            $testResultFileName = Join-Path -Path $script:testResultsDirectory -ChildPath "$($_.Directory.BaseName).xml"
        
            # Check if nunit or xunit is used as a test runner. They use diffrent parameters
            # for test result file path specification
            
            $testProjectJsonContent = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json
            if($testProjectJsonContent.testRunner -eq "xunit") {

                # the projects directory name is taken as the name of the test result file.
                &  $script:dotnet test -xml $testResultFileName

            } elseif($testProjectJsonContent.testRunner -eq "nunit") {

                # the projects directory name is taken as the name of the test result file.
                &  $script:dotnet test -result:$testResultFileName
            }
        
        } finally {
            Pop-Location
        }
    }

} -depends query_workspace,init_assemblies

Task report_test_assemblies -description "Retrieves a report of failed tests" {
    
    Get-ChildItem -Path $script:testResultsDirectory -Filter *.xml | ForEach-Object {
        
        $testResultContent = [xml](Get-Content $_.FullName)

        if((Select-Xml -Xml $testResultContent -XPath "//assembly")) {

            # must be xunit
            $failed = (Select-Xml -Xml $testResultContent -XPath "//test[@result != 'Pass']").Node | Select-Object Name,Result
            if(!$failed) {
                "No test failed: $($_.FullName)" | Write-Host -ForegroundColor Green
            } else {
                "Some tests failed: $($_.FullName)" | Write-Host -ForegroundColor Red
                $failed | Format-Table
            }

        } else { 
            
            # must be nunit
            $failed = (Select-Xml -Path $_.FullName -XPath "//test-case[@result != 'Passed']").Node | Select-Object Name,Result
            if(!$failed) {
                "No test failed: $($_.FullName)" | Write-Host -ForegroundColor Green
            } else {
                "Some tests failed: $($_.FullName)" | Write-Host -ForegroundColor Red
                $failed | Format-Table
            }
        }
    }        

} -depends query_workspace,init_assemblies

Task measure_assemblies -description "Run the benchmark projects under measure. Output is written to the .benchmark directory" {
    
    $script:projectItems.measure | ForEach-Object {

        Push-Location $_.Directory
        try {

            & $script:dotnet run

        } finally {
            Pop-Location
        }
    }

} -depends query_workspace

#endregion

#region Tasks for Nuget packages

Task init_packages {
 
    # nuget packages are stored in .packages. 
    # The directory is created if necessary

    if(Test-Path $PSScriptRoot\.packages) {
        $script:packageBuildDirectory = Get-Item -Path $PSScriptRoot\.packages
    } else {   
        $script:packageBuildDirectory = New-Item -Path $PSScriptRoot\.packages -ItemType Directory
    }
}

Task clean_packages -description "Removes nuget packages build directory" {
    
    Remove-Item $PSScriptRoot\.packages -Recurse -Force -ErrorAction SilentlyContinue
}

Task build_packages -description "Create nuget packages from all projects having packOptions defined" {
    
    $script:projectItems.src | ForEach-Object {

        Push-Location $_.Directory 
        try {
            $projectJsonContent = Get-Content -Path $_.FullName -Raw | ConvertFrom-Json

            if($projectJsonContent.packOptions -ne $null) {
                
                & $script:dotnet pack -c "Release" -o $script:packageBuildDirectory

            } else {
                "Skipping project $($_.Fullname). No packOptions defined." | Write-Host -ForegroundColor DarkYellow
            }
            
        } finally {
            Pop-Location
        }
    }

} -depends query_workspace,init_packages,clean_packages

Task publish_packages -description "Makes the packages known to the used package source" {
    
    # Publishing a package requires the nuget.exe. 
    # Credentials/api key of the package feed ist url are taken from the efective Nuget.Config

    Push-Location $script:packageBuildDirectory
    try {
        
        Get-ChildItem *.nupkg -Exclude *.symbols.nupkg | ForEach-Object {
            
            "Publishing: $($_.FullName)" | Write-Host    
            & $script:nuget push $_.FullName
        }

    } finally {
        Pop-Location
    }

} -depends query_workspace,init_packages

Task report_nugetConfig -description "Extracts some config values from the effective Nuget config" {
    
    "Nuget.Config Path: $env:APPDATA\nuget\NuGet.config" | Write-Host
    "Default NuGet Push Source: $(& $script:nuget config defaultPushSource)" | Write-Host
    "Known Api Keys:" | Write-Host
    $nugetConfigContentXml = [xml](Get-Content -Path $env:APPDATA\nuget\NuGet.config)
    $nugetConfigContentXml.configuration.apikeys.add | Format-Table -AutoSize
}

#endregion

#region Tasks for coverage reporting

Task init_coverage {

    # coverage information is stoired i n .coverage.
    # he directoyr is created if necessary

    if(Test-Path $PSScriptRoot\.coverage) {
        $script:coverageResultsDirectory = Get-Item -Path $PSScriptRoot\.coverage
    } else {   
        $script:coverageResultsDirectory = New-Item -Path $PSScriptRoot\.coverage -ItemType Directory
    }

    # Get Opencover
    & $script:nuget install OpenCover -Output $script:coverageResultsDirectory
    
    # Get hold on the OpenCover executable
    $script:openCoverConsole = Get-ChildItem -Path $script:coverageResultsDirectory -Filter OpenCover.Console.Exe -Recurse | Select-Object -ExpandProperty FullName

    # Get ReportGenerator
    & $script:nuget install ReportGenerator -Output $script:coverageResultsDirectory

    # Get Hold on ReportGerenator executable
    $script:reportGenerator = Get-ChildItem -Path $script:coverageResultsDirectory -Filter ReportGenerator.Exe -Recurse | Select-Object -ExpandProperty FullName
}

Task clean_coverage {
    
    Remove-Item -Path $PSScriptRoot\.coverage\* -Include @("*.xml","*.htm","*.png","*.css","*.js") -ErrorAction SilentlyContinue
}

Task build_coverage -description "Run the unit test under 'test' to measure the tests coverage. Output is written to .coverage directory" {

    # Run test projects with openCover and collect result separted by project in an XML file.
    
    $script:projectItems.test | ForEach-Object {
        $projectDirectory = $_.Directory
        Get-ChildItem "$($_.Directory.FullName)\bin\Debug\netcoreapp1.0\$($_.Directory.BaseName).Dll" -Recurse | ForEach-Object {
            "test assembly: $_" | Write-Host
            & $script:openCoverConsole -oldStyle -target:$script:dotnet -targetdir:$($projectDirectory.FullName) -targetargs:test -register:user -output:$script:coverageResultsDirectory\$($_.BaseName).xml
        }
    }

} -depends query_workspace,init_coverage,clean_coverage

Task report_coverage -description "Creates a report of the collected coverage data" {

    
    # Generate a report for avery coverage file found
    & $script:reportGenerator -targetdir:$script:coverageResultsDirectory -reports:([string]::Join(";",(Get-ChildItem -Path $script:coverageResultsDirectory -Filter *.xml | Select-Object -ExpandProperty FullName)))

    # Start b rowser woth coverage result 
    ii $script:coverageResultsDirectory\index.htm

} -depends query_workspace,init_coverage

#endregion

Task update_self {
    # Update this script directly from github
    Invoke-RestMethod https://raw.githubusercontent.com/wgross/PSake.NetCore/master/libs_and_tests.ps1 -OutFile $PSScriptRoot\default.ps1
}

#
# The default build pipeline
#

Task clean -description "The project tree is clean: all artifacts created by the development tool chain are removed"  -depends clean_assemblies,clean_packages,clean_coverage
Task restore -description "External dependencies are restored.The project is ready to be built." -depends build_dependencies
Task build -description "The project is built: all artifacts created by the development tool chain are created" -depends restore,build_assemblies
Task test -description "The project is tested: all automated tests of the project are run" -depends build,test_assemblies,report_test_assemblies
Task pack -description "All nuget packages are built" -depends build_packages
Task default -depends clean,restore,build,test,pack

#
# Additional build targets
# 

Task publish -description "All artefacts are published to their destinations" -depends publish_packages
Task report -description "Calls all reports" -depends report_test_assemblies
Task coverage -description "Starts a  coverage analysys of the workspace" -depends build_coverage,report_coverage
Task measure -description "The project is measured: all benchmarks are running" -depends build_assemblies,measure_assemblies

