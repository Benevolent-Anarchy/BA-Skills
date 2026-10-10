function New-PresetPrerequisiteFixture([string]$Missing='', [string]$GodotVersion='4.7.2.stable.official') {
    $fixture=@{missing=$Missing;godotVersion=$GodotVersion;calls=[Collections.Generic.List[string]]::new()}
    $fixture.probe={
        param($name)
        $fixture.calls.Add($name)
        return @{passed=($name -ne $fixture.missing);version=$(if($name -eq 'godot'){$fixture.godotVersion}else{'fixture'});executable='fixture';message=$(if($name -eq $fixture.missing){"Missing $name"}else{''})}
    }.GetNewClosure()
    return $fixture
}
function New-PresetMetadataFixture {
    $fixture=@{fail=$false;calls=[Collections.Generic.List[string]]::new();tauri=@{versions=@(@{num='3.0.0';yanked=$false},@{num='3.1.0-beta.1';yanked=$false},@{num='9.0.0';yanked=$true},@{num='2.99.0';yanked=$false})};npm=@{'dist-tags'=@{latest='4.0.0'};versions=@{'4.0.0'=@{version='4.0.0';dist=@{tarball='https://registry.npmjs.org/create-tauri-app/-/create-tauri-app-4.0.0.tgz';integrity=('sha512-'+[Convert]::ToBase64String([byte[]]::new(64)))}}}}}
    $fixture.request={param($uri)
        $fixture.calls.Add($uri)
        if ($fixture.fail) {throw 'HTTP metadata unavailable'}
        switch ($uri) {
            'https://crates.io/api/v1/crates/tauri' {return $fixture.tauri}
            'https://registry.npmjs.org/create-tauri-app' {return $fixture.npm}
            'https://api.github.com/repos/bitwes/Gut/git/ref/tags/v9.7.1' {return @{object=@{type='commit';sha=('a'*40)}}}
            default {throw "Unexpected metadata URI: $uri"}
        }
    }.GetNewClosure()
    return $fixture
}
function New-TauriProcessFixture {
    $fixture=@{mode='pass';calls=[Collections.Generic.List[object]]::new();version='3.0.0'}
    $fixture.metadata={
        $appId='path+file:///fixture/src-tauri#starter@0.0.1';$tauriId="registry+https://github.com/rust-lang/crates.io-index#tauri@$($fixture.version)"
        return @{packages=@(@{id=$appId;name='starter';version='0.0.1'},@{id=$tauriId;name='tauri';version=$fixture.version});resolve=@{root=$appId;nodes=@(@{id=$appId;deps=@(@{name='tauri';pkg=$tauriId})})}}
    }.GetNewClosure()
    $fixture.process={param($exe,$arguments,$cwd,$environment)
        $fixture.calls.Add(@{exe=$exe;arguments=$arguments;cwd=$cwd;environment=$environment})
        if ($arguments -contains 'create-tauri-app' -and $arguments -contains '--help') {return @{ExitCode=0;Output='4.0.0 --template vanilla-ts --manager --identifier --yes --tauri-version [1 | 2 | 3]';Executable=$exe}}
        if ($arguments -contains 'create-tauri-app' -and $arguments -contains '.') {
            foreach ($path in @('src/main.ts','src/styles.css','src-tauri/build.rs','src-tauri/src/main.rs','src-tauri/src/lib.rs','tsconfig.json','vite.config.ts','index.html')) {Write-FixtureText "$cwd/$path" 'upstream source'}
            Write-FixtureText "$cwd/vite.config.ts" 'export default {server: {port: 1420, strictPort: true, watch: {ignored: ["**/src-tauri/**"]}}}'
            Write-FixtureText "$cwd/package.json" '{"name":"upstream","version":"0.1.0","type":"module","scripts":{"dev":"vite","build":"tsc && vite build","tauri":"tauri"},"dependencies":{"@tauri-apps/api":"^3"},"devDependencies":{"@tauri-apps/cli":"^3","typescript":"latest","vite":"latest"}}'
            Write-FixtureText "$cwd/src-tauri/Cargo.toml" "[package]`nname = `"starter`"`nversion = `"0.1.0`"`n[lib]`nname = `"starter_lib`"`n[dependencies]`ntauri = { version = `"3`", features = [] }`n"
            Write-FixtureText "$cwd/src-tauri/tauri.conf.json" '{"$schema":"https://schema.tauri.app/config/3","productName":"starter","version":"0.1.0","identifier":"com.example.starter","build":{"beforeDevCommand":"npm run dev","beforeBuildCommand":"npm run build","devUrl":"http://localhost:1420","frontendDist":"../dist"},"app":{"windows":[{"title":"starter"}]},"bundle":{"icon":["icons/icon.ico"]}}'
            if ($fixture.mode -ne 'layout') {Write-FixtureText "$cwd/src-tauri/capabilities/default.json" '{"identifier":"default","windows":["main"],"permissions":["core:default"]}'}
            Write-FixtureText "$cwd/.gitignore" 'upstream.cache/'
            Write-FixtureText "$cwd/src-tauri/.gitignore" "/target/`n/gen/schemas"
            [IO.Directory]::CreateDirectory("$cwd/src-tauri/icons") | Out-Null
            [IO.File]::WriteAllBytes("$cwd/src-tauri/icons/icon.ico",[byte[]]@(0,255,128,10,13))
        }
        if ($arguments -contains '--package-lock-only' -and $fixture.mode -ne 'locks') {
            $package=[IO.File]::ReadAllText("$cwd/package.json") | ConvertFrom-Json -AsHashtable
            @{lockfileVersion=3;name=$package.name;version=$package.version;packages=@{''=$package}} | ConvertTo-Json -Depth 8 | ForEach-Object {Write-FixtureText "$cwd/package-lock.json" $_}
        }
        if ($arguments -contains 'generate-lockfile' -and $fixture.mode -ne 'locks') {Write-FixtureText "$cwd/src-tauri/Cargo.lock" 'version = 4'}
        if ($arguments -contains 'ci' -and $arguments -notcontains '--dry-run' -and $fixture.mode -ne 'install') {[IO.Directory]::CreateDirectory("$cwd/node_modules") | Out-Null}
        if ($arguments -contains 'metadata') {return @{ExitCode=0;Output=(& $fixture.metadata | ConvertTo-Json -Depth 8);Executable=$exe}}
        if ($environment.ContainsKey('BA_TAURI_RESULTS')) {
            if ($fixture.mode -ne 'report') {Write-FixtureText $environment.BA_TAURI_RESULTS '<testsuites name="vitest" tests="1" failures="0" errors="0"><testsuite tests="1" skipped="0"><testcase name="entry point" /></testsuite></testsuites>'}
        }
        if ($arguments -contains '--no-bundle') {[IO.Directory]::CreateDirectory("$cwd/src-tauri/target/release") | Out-Null;[IO.File]::WriteAllBytes("$cwd/src-tauri/target/release/starter.exe",[byte[]]@(1,2))}
        $fail=($fixture.mode -eq 'install' -and $arguments -contains 'ci') -or ($environment.ContainsKey('BA_TAURI_STAGE') -and $fixture.mode -ceq $environment.BA_TAURI_STAGE)
        return @{ExitCode=$(if($fail){1}else{0});Output=$(if($fail){'fixture native failure'}else{'fixture output'});Executable=$exe}
    }.GetNewClosure()
    return $fixture
}
