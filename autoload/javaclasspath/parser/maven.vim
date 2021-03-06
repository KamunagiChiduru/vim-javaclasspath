"
" The MIT License (MIT)
"
" Copyright (c) 2014 kamichidu
"
" Permission is hereby granted, free of charge, to any person obtaining a copy
" of this software and associated documentation files (the "Software"), to deal
" in the Software without restriction, including without limitation the rights
" to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
" copies of the Software, and to permit persons to whom the Software is
" furnished to do so, subject to the following conditions:
"
" The above copyright notice and this permission notice shall be included in
" all copies or substantial portions of the Software.
"
" THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
" IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
" FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
" AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
" LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
" OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
" THE SOFTWARE.
"
let s:save_cpo= &cpo
set cpo&vim

let s:V= vital#of('javaclasspath')
let s:P= s:V.import('Process')
let s:XML= s:V.import('Web.XML')
let s:JLang= s:V.import('Java.Lang')
let s:Path= s:V.import('System.Filepath')
unlet s:V

" cache file structure
"
" - pom
"   - mtime
"   - filepath
" - cache

let s:obj= {
\   'name': 'maven',
\   'config': {
\       'filename': {
\           'type':     type(''),
\           'required': 1,
\       },
\       'command': {
\           'type': type(''),
\           'required': 1,
\       },
\   },
\}

function! s:obj.parse(config)
    if !(filereadable(a:config.filename) && executable(a:config.command))
        return []
    endif
    let pom_file= fnamemodify(a:config.filename, ':p')
    let storage= javaclasspath#storage#new(pom_file)

    let mtime= getftime(pom_file)
    if storage.has('pom')
        let pom_info= storage.get('pom')
        if pom_info.mtime >= mtime
            return pom_info.cache
        endif
    endif

    call s:build_classpath(a:config)
    call s:generate_effective_pom(a:config)

    call storage.load()

    " wait
    let epom_memo= storage.get('epom')
    while !storage.has('epom_status')
        let status= s:status(epom_memo.stdout, epom_memo.stderr)
        if status !=# ''
            call storage.set('epom_status', status)
            call storage.persist()
            break
        endif
        sleep 10 m
        call storage.load()
    endwhile
    if storage.get('epom_status') ==# 'FAILURE'
        return []
    endif
    let epom_dom= s:XML.parseFile(epom_memo.epom_path)

    let paths= []
    " collect sourcepath
    let source_dir= epom_dom.find('sourceDirectory').value()
    if isdirectory(source_dir)
        let paths+= [{'kind': 'src', 'path': source_dir}]
    endif
    let script_source_dir= epom_dom.find('scriptSourceDirectory').value()
    if isdirectory(script_source_dir)
        let paths+= [{'kind': 'src', 'path': script_source_dir}]
    endif
    let test_source_dir= epom_dom.find('testSourceDirectory').value()
    if isdirectory(test_source_dir)
        let paths+= [{'kind': 'src', 'path': test_source_dir}]
    endif
    let output_dir= epom_dom.find('outputDirectory').value()
    if isdirectory(output_dir)
        let paths+= [{'kind': 'lib', 'path': output_dir}]
    endif
    let test_output_dir= epom_dom.find('testOutputDirectory').value()
    if isdirectory(test_output_dir)
        let paths+= [{'kind': 'lib', 'path': test_output_dir}]
    endif
    for child in epom_dom.find('resources').findAll('directory')
        let resource_dir= child.value()
        if isdirectory(resource_dir)
            let paths+= [{'kind': 'src', 'path': resource_dir}]
        endif
    endfor
    for child in epom_dom.find('testResources').findAll('directory')
        let test_resource_dir= child.value()
        if isdirectory(test_resource_dir)
            let paths+= [{'kind': 'src', 'path': test_resource_dir}]
        endif
    endfor

    let cp_memo= storage.get('cp')
    while !storage.has('cp_status')
        let status= s:status(cp_memo.stdout, cp_memo.stderr)
        if status !=# ''
            call storage.set('cp_status', status)
            call storage.persist()
            break
        endif
        sleep 10 m
        call storage.load()
    endwhile
    if storage.get('cp_status') ==# 'FAILURE'
        return []
    endif

    " collect classpath
    let classpaths= split(join(readfile(cp_memo.cp_path), ''), s:JLang.path_separator)
    for classpath in classpaths
        let entry= {'kind': 'lib', 'path': classpath}
        let javadoc_path= substitute(classpath, '\.jar$', '-javadoc.jar', '')
        let source_path= substitute(classpath, '\.jar$', '-sources.jar', '')

        if filereadable(javadoc_path)
            let entry.javadoc= javadoc_path
        endif
        if filereadable(source_path)
            let entry.sourcepath= source_path
        endif

        let paths+= [entry]
    endfor

    call storage.set('pom', {
    \   'mtime': mtime,
    \   'cache': paths,
    \})
    call storage.persist()

    return paths
endfunction

function! javaclasspath#parser#maven#on_filetype(config)
    if &l:filetype !=# 'java'
        return
    endif
    if filereadable(a:config.filename)
        call s:generate_effective_pom(a:config)
        call s:build_classpath(a:config)
    endif
endfunction

function! javaclasspath#parser#maven#define()
    return deepcopy(s:obj)
endfunction

function! s:status(stdoutfile, stderrfile)
    " maven don't output stderr
    if !filereadable(a:stdoutfile)
        return ''
    endif

    let lines= readfile(a:stdoutfile)
    for line in lines
        if line =~# '\cBUILD\s\+\%(SUCCESS\|FAILURE\)'
            return matchstr(line, '\cBUILD\s\+\zs\%(SUCCESS\|FAILURE\)\ze')
        endif
    endfor
    return ''
endfunction

function! s:generate_effective_pom(config)
    let pom_file= fnamemodify(a:config.filename, ':p')
    let storage= javaclasspath#storage#new(pom_file)
    let mem= storage.get('epom', {})

    let mtime= getftime(pom_file)
    if has_key(mem, 'mtime') && mem.mtime >= mtime && storage.get('epom_status', '') ==# 'SUCCESS'
        return
    endif
    let mem.mtime= mtime
    let mem.epom_path= s:Path.join(g:javaclasspath_data_dir, 'epom', javaclasspath#util#safe_filename(pom_file))
    let mem.stdout= tempname()
    let mem.stderr= tempname()

    if !isdirectory(fnamemodify(mem.epom_path, ':h'))
        call mkdir(fnamemodify(mem.epom_path, ':h'), 'p')
    endif

    call storage.set('epom', mem)
    call storage.remove('epom_status')
    call storage.persist()

    call javaclasspath#util#spawn(join([
    \   a:config.command,
    \   printf('--file "%s"', pom_file),
    \   'help:effective-pom',
    \   printf('-Doutput="%s"', mem.epom_path),
    \   printf('>"%s"', mem.stdout),
    \   printf('2>"%s"', mem.stderr),
    \]), 1)
endfunction

function! s:build_classpath(config)
    let pom_file= fnamemodify(a:config.filename, ':p')
    let storage= javaclasspath#storage#new(pom_file)
    let mem= storage.get('cp', {})

    let mtime= getftime(pom_file)
    if has_key(mem, 'mtime') && mem.mtime >= mtime && storage.get('cp_status', '') ==# 'SUCCESS'
        return
    endif
    let mem.mtime= mtime
    let mem.cp_path= s:Path.join(g:javaclasspath_data_dir, 'classpath', javaclasspath#util#safe_filename(pom_file))
    let mem.stdout= tempname()
    let mem.stderr= tempname()

    if !isdirectory(fnamemodify(mem.cp_path, ':h'))
        call mkdir(fnamemodify(mem.cp_path, ':h'), 'p')
    endif

    call storage.set('cp', mem)
    call storage.remove('cp_status')
    call storage.persist()

    call javaclasspath#util#spawn(join([
    \   a:config.command,
    \   printf('--file "%s"', pom_file),
    \   'dependency:build-classpath',
    \   printf('-Dmdep.outputFile="%s"', mem.cp_path),
    \   printf('>"%s"', mem.stdout),
    \   printf('2>"%s"', mem.stderr),
    \]), 1)
endfunction

let &cpo= s:save_cpo
unlet s:save_cpo
