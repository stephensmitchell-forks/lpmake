function New-ProjectFromLinqpadQuery
{
	<#
	.Synopsis
		Creates a new project from specified linqpad query and build it.
	.Example
		PS> New-ProjectFromLinqpadQuery .\MyQuery.linq
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory=$true)]
		[string] $QueryPath,

		# Used to store the generated files; will create a new temporary directory if not specified.
		[string] $TargetDir,

		# Sometimes we want to use the generated project name as the target directory name, which means
		# we cannot use TargetDir to specify that, this optional parameter can help with that: when
		# TargetDir is not specified and this TargetBaseDir is specified, the TargetDir will be generated
		# based on the TargetBaseDir + Generated_Name_from_QueryPath.
		[string] $TargetBaseDir,

		# Used as the source file name as well as assembly and namespace name; will be inferrred from the query file if not specified.
		[string] $Name,

		# TODO: how do I detect this from code using Roslyn?
		[switch] $Unsafe,

		[ValidateSet('Library', 'Exe', 'WinExe')]
		[string] $OutputType = 'Library',

        # Used when compile as Exe and using LinqPad extension method Dump, you need to have
        # a nuget package with this name; see Readme for more info. If you are not using
		# Dump extension method then you can set this to null to avoid having an extra dependency.
		[string] $ObjectDumper = 'ObjectDumperLib',

        # Immediately load the built assembly into PowerShell
        [switch] $Load,

        # Publish as a nuget package using command `Publish-MyNugetPackage` which you needs
        # to define yourself, it requires a mandatory parameter which is the package id.
        [switch] $Publish,

		[switch] $Force,

		# used when restore packages
		[string[]] $NugetSources
		)
	$csharpImports = @(
			'System'
			'System.IO'
			'System.Text'
			'System.Text.RegularExpressions'
			'System.Diagnostics'
			'System.Threading'
			'System.Reflection'
			'System.Collections'
			'System.Collections.Generic'
			'System.Linq'
			'System.Linq.Expressions'
			'System.Data'
			'System.Data.SqlClient'
			'System.Data.Linq'
			'System.Data.Linq.SqlClient'
			'System.Xml'
			'System.Xml.Linq'
			'System.Xml.XPath'
		)
	$fsharpImports = @(
			'System'
			'System.IO'
			'System.Text'
			'System.Text.RegularExpressions'
			'System.Diagnostics'
			'System.Threading'
			'System.Reflection'
		)

    function Resolve-NugetReferenceVersions($nugetReferences, $lockFile) {
		# Unless you are locking to use a specific version of nuget package in Linqpad query, the
		# version field will be null, but when we publish a nuget package we must resolve the actual
		# versions; we can use the project.lock.json file generated by `nuget restore project.json` 
		# to resolve the versions.
        if (!(Test-Path $lockFile)) { throw "Unable to find $lockFile" }
        $data = ConvertFrom-JsonFile $lockFile
		$versions = @{}
		$data.libraries.keys | % { 
			$id, $version = $_.Split('/', 2)
			$versions[$id] = $version
		}
		$nugetReferences | % { 
			$_.Version = $versions[$_.Name]
		}
	}

	function GetCommonNamespaces($namespaces, $fsharp) {
		$(if ($fsharp) { $fsharpImports } else { $csharpImports }) | % {
			if ($fsharp) {
				"open $_"
			} else {
				"using $_;"
			}
		}

		foreach($ns in $namespaces) {
			if ($fsharp) {
				"open $ns"
			} else {
				"using $ns;"
			}
		}
	}
	
	function AddNamespace($query, $ns) {
		if (!$query.Namespaces) { $query.Namespaces = @() }
		if ($query.Namespaces -notcontains $ns) { $query.Namespaces += $ns }
	}

	function AddNugetRef($query, $name, $version) {
		if (!$query.NuGetReferences) { $query.NugetReferences = @() }
		$existing = $query.NugetReferences | ? { $_.Name -eq $name }
		if (!$existing) {
			$newobj = [PsCustomObject] @{
				Name = $name
				Version = $version
			}
			$query.NugetReferences += $newobj
		}
	}

	$ErrorActionPreference = 'Stop'

	if (!$Name) { 
		$Name = [IO.Path]::GetFileNameWithoutExtension($QueryPath)
		' `!@#$%^&*()-+=[]{},;''"'.ToCharArray() | % {
			$Name = $Name.Replace($_.ToString(), '')
		}
	}

	if (!$TargetDir) { 
		if (!$TargetBaseDir) { $TargetDir = New-TempDirectory }
		else { $TargetDir = Join-Path $TargetBaseDir $Name }
	}

	if (!(Test-Path $TargetDir)) { mkdir $TargetDir | Out-Null }

	$query = ConvertFrom-LinqpadQuery $QueryPath
	$supportedKinds = @('Program', 'FSharpProgram')
	if ($supportedKinds -notcontains $query.Kind) { 
		throw "Currently only supports following kinds: $($supportedKinds -join ', '); the query $QueryPath has kind: $($query.Path)" 
	}
	$fsharp = $(if ($query.Kind -eq 'FSharpProgram') { $true })
	$islib = $OutputType -eq 'Library'

	# Lines after the flags are considered top level classes; before it are
	# embedded code which needs to be wrapped in a class with entry point if 
	# we are creating exe.
	$FLAG= '^(// Define other methods and classes here|//////////)'
	$flagFound = $false
	$libcode = @()
	$maincode = @()
	$exeOnly = @{}
	$mainIsVoid = $true
	$mainHasArgs = $false
	$hasStaticMain = $false
	$entryFound = $false
	foreach($line in $query.Code) {
		if (!$entryFound -AND ($line -match '(static )?(void|int) Main\((string\[\] args)?\)')) {
			if ($matches[1]) {
				# if it has static Main then we should use it as-is
				$hasStaticMain = $true
			} 
			if ($matches[2] -eq 'int') { $mainIsVoid = $false }
			if ($matches[3]) { $mainHasArgs = $true }
			if (!$hasStaticMain) {
				$line = "$($matches[2]) MainMain($($matches[3]))"
			}
			$entryFound = $true
		}

		if (!$flagFound -AND ($line -match $FLAG)) {
			$flagFound = $true
		} elseif ($flagFound) {
			$libcode += $line
		} else {
			$maincode += $line
		}

		# any line starts with `// lpmake ` will be treated as additional configurations we can process, which are
		# written as PowerShell hashtable, such as `@{Unsafe=$true}`
		if ($line -match '^// \s*lpmake\s+') {
			$options = Invoke-Expression $line.Substring($matches[0].Length)
			if ($options.Unsafe) { $Unsafe = [switch] $true }
			if ($options.ExeOnly) {
				# Specify which references and namespaces are only used in the 'Exe' part of the linq query, so that 
				# when creating the library and/or publish as nuget packages, these dependencies will be removed.
				# sample: 
				# @{ExeOnly = @{NugetPackages = @('package1', 'package2'); Assemblies = @('c:\temp\foo.dll'); GacAssemblies = @('System.Windows.Forms'); Namespaces=@('System.Windows.Forms')}}
				$exeOnly = $options.ExeOnly
			}
		}

	}

	if ($fsharp) {
		# in the case of F# program, test code will be after library code
		$libcode, $maincode = $maincode, $libcode
	}

	if ($islib -AND ($libcode.Length -eq 0)) {
		# only validate when it is a library but no library code found
		throw "No valid library code found; please ensure you have $FLAG in source, only code after it will be compiled."
	}

	# handle exeOnly options
	if ($islib -AND $exeOnly) {
		if ($exeOnly.NugetPackages) {
			[array] $query.NugetReferences = $query.NugetReferences | ? { $exeOnly.NugetPackages -notcontains $_.Name }
		}
		if ($exeOnly.Assemblies) {
			[array] $query.References = $query.References | ? { $exeOnly.Assemblies -notcontains $_ }
		}
		if ($exeOnly.GacAssemblies) {
			[array] $query.GacReferences = $query.GacReferences | ? { $exeOnly.GacAssemblies -notcontains $_.Name }
		}
		if ($exeOnly.Namespaces) {
			[array] $query.Namespaces = $query.Namespaces | ? { $exeOnly.Namespaces -notcontains $_ }
		}
	}

	# change to WinExe using exeOnly options
	if (!$islib -AND $exeOnly.OutputType) {
		$OutputType = $exeOnly.OutputType	
	}

	# validate files to be written don't exist already
	$ft = $(if ($fsharp) { 'f' } else { 'c' })
	$projectFile = [IO.Path]::Combine($TargetDir, "$Name.${ft}sproj")
	if (!$Force -AND (Test-Path $projectFile)) { throw "$projectFile already exists" }
	$sourceFile = [IO.Path]::Combine($TargetDir, "$Name.${ft}s")
	if (!$Force -ANd (Test-Path $sourceFile)) { throw "$sourceFile already exists" }
    $projectJson = [IO.Path]::Combine($TargetDir, "project.json")

	# generate project.json
    if (!$islib -and $ObjectDumper) {
        AddNamespace $query $ObjectDumper
        AddNugetRef $query $ObjectDumper '*'
    }

    if ($fsharp) {
        if (!$islib -AND $ObjectDumper) {
            AddNamespace $query $ObjectDumper
        }
        AddNugetRef $query 'FSharp.Core' '4.0.0.1'
    }
	if ($query.NugetReferences) {
        $query.NugetReferences | New-ProjectJson -NugetSources $NugetSources | Out-File $projectJson -Encoding UTF8
    }

	# generate source file
	$(
		if ($fsharp) {
			if ($islib) {
				"namespace $Name"
			}
		} else {
			"namespace $Name"
			'{'
		}
		GetCommonNamespaces $query.Namespaces $fsharp

		if (!$fsharp) {
			if (!$islib) {
				if (!$hasStaticMain) {
				@"
				internal class Program 
				{
					$(if ($OutputType -eq 'WinExe') { '[System.STAThread]' }) 
					static $(if ($mainIsVoid) { 'void' } else { 'int' }) Main(string[] args) {
						$(if ($mainIsVoid) { '' } else { 'return' }) new Program().MainMain($(if ($mainHasArgs) { 'args' } else { '' }));
					}
"@
				}
				$maincode
				if (!$hasStaticMain) {
				'}'
				}
			}

			'#region LPMAKE'
			$libcode
			'#endregion LPMAKE'
			'}'
		} else {
			if (!$islib) {
				if ($ObjectDumper) {
					'let Dump = ObjectDumper.Write'
				}
				$query.Code
			} else {
				$libcode
			}
		}
	) | Out-File $sourceFile -Encoding UTF8

	# generate config files
	$contents = @()
	if ($query.NugetReferences) {
		$contents = @('project.json')
	}

	$references = $(
		if ($query.References) {
			$query.References
		}
		if ($query.GacReferences) {
			$query.GacReferences | % {
				$_.FullName
			}
		}
	)

	# generate project file
	if ($islib) {
		$conditions = ''
	} else {
		$conditions = ';CMD'
	}
	if ($fsharp) {
		$content = New-Fsproj -Name $Name -References $references -Sources @([IO.Path]::GetFileName($sourceFile)) -Contents $contents -OutputType $OutputType -Conditions $conditions
	} else {
		$content = New-Csproj -Name $Name -References $references -Sources @([IO.Path]::GetFileName($sourceFile)) -Contents $contents -Unsafe:$Unsafe -OutputType $OutputType -Conditions $conditions
	}
	$content | Out-File $projectFile -Encoding UTF8

	Push-Location $TargetDir
	if ($query.NuGetReferences) {
		$nugetArgs = @('restore', $projectJson)
		if ($NugetSources) {
			$NugetSources | % {
				$nugetArgs += ('-source', $_)
			}
		}
		# Nuget 3.4 is not able to restore project.json created by this script, while
		# nuget 3.3 does work; I haven't yet figured out the specific changes required to 
		# be made in project.json, given the fact that there will be changes to project.json
		# and msbuild due to .net core not reached RTW yet, I will only use nuget.exe 3.3 
		# here, which we will download if not found in specific folder.
		$nugetExe = "$PsScriptRoot\nuget.exe"
		if (!(Test-Path $nugetExe)) {
			$nugetExeUrl = 'https://dist.nuget.org/win-x86-commandline/v3.3.0/nuget.exe'
			Invoke-WebRequest $nugetExeUrl -OutFile $nugetExe
		}
		& $nugetExe @nugetArgs

        Resolve-NugetReferenceVersions $query.NugetReferences 'project.lock.json'
	}

	$msbuild = "$([Environment]::GetFolderPath('ProgramFilesX86'))\Msbuild\14.0\bin\msbuild.exe"
	if (!(Test-Path $msbuild)) { 
		throw "Unable to find $msbuild"
	}

	& $msbuild /nologo /v:q $projectFile
    if ($LastExitCode -eq 0) {
        if ($islib) {
            if ($Load) {
                Add-Type -Path "bin\debug\$Name.dll"
            }
            if ($Publish) {
				$prerelease = [switch] $false
				if ($query.NugetReferences) {
					$query.NugetReferences | New-NugetSpec | Out-File "$Name.nuspec" -Encoding UTF8
					if ($query.NugetReferences | ? { $_.Prerelease }) {
						$prerelease = [switch] $true
					}
				}
				Publish-MyNugetPackage $Name -Prerelease:$prerelease
            }
        }
    }
}

Set-Alias lpmake New-ProjectFromLinqpadQuery -Force
