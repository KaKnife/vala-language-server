using LanguageServer;
using Gee;

struct CompileCommand {
    string path;
    string directory;
    string command;
}

enum Vls.CompletionType {
    /**
     * for MemberAccess and PointerIndirection
     */
    MemberAccess,

    /* TODO: add more categories */
}

class Vls.TextDocument : Object {
    private Context ctx;
    private string filename;

    public Vala.SourceFile file;
    public string uri;
    public int version;

    public TextDocument (Context ctx, 
                         string filename, 
                         string? content = null,
                         int version = 0) throws ConvertError {
        this.uri = Filename.to_uri (filename);
        this.filename = filename;
        this.version = version;
        this.ctx = ctx;

        var type = Vala.SourceFileType.NONE;
        if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            type = Vala.SourceFileType.SOURCE;
        else if (uri.has_suffix (".vapi"))
            type = Vala.SourceFileType.PACKAGE;

        file = new Vala.SourceFile (ctx.code_context, type, filename, content);
        if (type == Vala.SourceFileType.SOURCE) {
            var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
            file.add_using_directive (ns_ref);
            ctx.add_using ("GLib");
        }
    }
}

class Vls.Server {
    FileStream log;
    Jsonrpc.Server server;
    MainLoop loop;
    HashTable<string, CompileCommand?> cc;
    Context ctx;
    HashTable<string, NotificationHandler> notif_handlers;

    [CCode (has_target = false)]
    delegate void NotificationHandler (Vls.Server self, Jsonrpc.Client client, Variant @params);

    public Server (MainLoop loop) {
        this.loop = loop;

        this.cc = new HashTable<string, CompileCommand?> (str_hash, str_equal);

        // initialize logging
        log = FileStream.open (@"$(Environment.get_tmp_dir())/vls-$(new DateTime.now_local()).log", "a");
        Posix.dup2 (log.fileno (), Posix.STDERR_FILENO);
        Timeout.add (3000, () => {
            log.printf (@"$(new DateTime.now_local()): listening...\n");
            return log.flush() != Posix.FILE.EOF;
        });

        // libvala setup
        this.ctx = new Vls.Context ();

        this.server = new Jsonrpc.Server ();
        var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
        var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
        server.accept_io_stream (new SimpleIOStream (stdin, stdout));

        notif_handlers = new HashTable <string, NotificationHandler> (str_hash, str_equal);

        server.notification.connect ((client, method, @params) => {
            log.printf (@"Got notification! $method\n");
            if (notif_handlers.contains (method))
                ((NotificationHandler) notif_handlers[method]) (this, client, @params);
            else
                log.printf (@"no handler for $method\n");
        });

        server.add_handler ("initialize", this.initialize);
        server.add_handler ("shutdown", this.shutdown);
        server.add_handler ("textDocument/completion", this.textDocumentCompletion);
        notif_handlers["exit"] = this.exit;

        server.add_handler ("textDocument/definition", this.textDocumentDefinition);
        notif_handlers["textDocument/didOpen"] = this.textDocumentDidOpen;
        notif_handlers["textDocument/didChange"] = this.textDocumentDidChange;

        log.printf ("Finished constructing\n");
    }

    // a{sv} only
    Variant buildDict (...) {
        var builder = new VariantBuilder (new VariantType ("a{sv}"));
        var l = va_list ();
        while (true) {
            string? key = l.arg ();
            if (key == null) {
                break;
            }
            Variant val = l.arg ();
            builder.add ("{sv}", key, val);
        }
        return builder.end ();
    }

    void showMessage (Jsonrpc.Client client, string message, MessageType type) {
        try {
            client.send_notification ("window/showMessage", buildDict(
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ));
        } catch (Error e) {
            log.printf (@"showMessage: failed to notify client: $(e.message)\n");
        }
    }

    void reply_to_client (string method, Jsonrpc.Client client, Variant id, Variant thing) {
        try {
            client.reply (id, thing);
        } catch (Error e) {
            log.printf ("%s: Failed to reply to client: %s\n", method, e.message);
        }
    }

    bool is_source_file (string filename) {
        return filename.has_suffix (".vapi") || filename.has_suffix (".vala")
            || filename.has_suffix (".gs");
    }

    bool is_c_source_file (string filename) {
        return filename.has_suffix (".c") || filename.has_suffix (".h");
    }

    void meson_analyze_build_dir (Jsonrpc.Client client, string rootdir, string builddir) {
        string[] spawn_args = {"meson", "introspect", builddir, "--targets"};
        string[]? spawn_env = null; // Environ.get ();
        string proc_stdout;
        string proc_stderr;
        int proc_status;

        log.printf (@"analyzing build directory $rootdir ...\n");
        try {
            Process.spawn_sync (rootdir, 
                spawn_args, spawn_env,
                SpawnFlags.SEARCH_PATH,
                null,
                out proc_stdout,
                out proc_stderr,
                out proc_status
            );
        } catch (SpawnError e) {
            showMessage (client, @"Failed to spawn $(spawn_args[0]): $(e.message)", MessageType.Error);
            log.printf (@"failed to spawn process: $(e.message)\n");
            return;
        }

        if (proc_status != 0) {
            showMessage (client, 
                @"Failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr", 
                MessageType.Error);
            log.printf (@"failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr\n");
            return;
        }

        // we should have a list of targets in JSON format
        string targets_json = proc_stdout;
        var targets_parser = new Json.Parser.immutable_new ();
        try {
            targets_parser.load_from_data (targets_json);
        } catch (Error e) {
            log.printf (@"failed to load targets for build dir $(builddir): $(e.message)\n");
            return;
        }

        // for every target, get all files
        var node = targets_parser.get_root ().get_array ();
        node.foreach_element ((arr, index, node) => {
            var o = node.get_object ();
            string id = o.get_string_member ("id");
            string fname = o.get_string_member ("filename");
            string[] args = {"meson", "introspect", builddir, "--target-files", id};

            if (fname.has_suffix (".vapi")) {
                if (!Path.is_absolute (fname)) {
                    fname = Path.build_filename (builddir, fname);
                }
                try {
                    var doc = new TextDocument (ctx, fname);
                    ctx.add_source_file (doc);
                    log.printf (@"Adding text document: $fname\n");
                } catch (Error e) {
                    log.printf (@"Failed to create text document: $(e.message)\n");
                }
            }
            
            try {
                Process.spawn_sync (rootdir, 
                    args, spawn_env,
                    SpawnFlags.SEARCH_PATH,
                    null,
                    out proc_stdout,
                    out proc_stderr,
                    out proc_status
                );
            } catch (SpawnError e) {
                log.printf (@"Failed to analyze target $id: $(e.message)\n");
                return;
            }

            // proc_stdout is a collection of files
            // add all source files to the project
            string files_json = proc_stdout;
            var files_parser = new Json.Parser.immutable_new ();
            try {
                files_parser.load_from_data (files_json);
            } catch (Error e) {
                log.printf (@"failed to get target files for $id (ID): $(e.message)\n");
                return;
            }
            var fnode = files_parser.get_root ().get_array ();
            fnode.foreach_element ((arr, index, node) => {
                var filename = node.get_string ();
                if (!Path.is_absolute (filename)) {
                    filename = Path.build_filename (rootdir, filename);
                }
                if (is_source_file (filename)) {
                    try {
                        var doc = new TextDocument (ctx, filename);
                        ctx.add_source_file (doc);
                        log.printf (@"Adding text document: $filename\n");
                    } catch (Error e) {
                        log.printf (@"Failed to create text document: $(e.message)\n");
                    }
                } else if (is_c_source_file (filename)) {
                    try {
                        ctx.add_c_source_file (Filename.to_uri (filename));
                        log.printf (@"Adding C source file: $filename\n");
                    } catch (Error e) {
                        log.printf (@"Failed to add C source file: $(e.message)\n");
                    }
                } else {
                    log.printf (@"Unknown file type: $filename\n");
                }
            });
        });

        // get all dependencies
        spawn_args = {"meson", "introspect", builddir, "--dependencies"};
        try {
            Process.spawn_sync (rootdir, 
                spawn_args, spawn_env,
                SpawnFlags.SEARCH_PATH,
                null,
                out proc_stdout,
                out proc_stderr,
                out proc_status
            );
        } catch (SpawnError e) {
            showMessage (client, e.message, MessageType.Error);
            log.printf (@"failed to spawn process: $(e.message)\n");
            return;
        }

        // we should have a list of dependencies in JSON format
        string deps_json = proc_stdout;
        var deps_parser = new Json.Parser.immutable_new ();
        try {
            deps_parser.load_from_data (deps_json);
        } catch (Error e) {
            log.printf (@"failed to load dependencies for build dir $(builddir): $(e.message)\n");
            return;
        }

        var deps_node = deps_parser.get_root ().get_array ();
        deps_node.foreach_element ((arr, index, node) => {
            var o = node.get_object ();
            var name = o.get_string_member ("name");
            ctx.add_package (name);
            log.printf (@"adding package $name\n");
        });
    }

    void cc_analyze (string root_dir) {
        log.printf ("looking for compile_commands.json in %s\n", root_dir);
        string ccjson = findCompileCommands (root_dir);
        if (ccjson != null) {
            log.printf ("found at %s\n", ccjson);
            var parser = new Json.Parser.immutable_new ();
            try {
                parser.load_from_file (ccjson);
                var ccnode = parser.get_root ().get_array ();
                ccnode.foreach_element ((arr, index, node) => {
                    var o = node.get_object ();
                    string dir = o.get_string_member ("directory");
                    string file = o.get_string_member ("file");
                    string path = File.new_for_path (Path.build_filename (dir, file)).get_path ();
                    string cmd = o.get_string_member ("command");
                    log.printf ("got args for %s\n", path);
                    cc.insert (path, CompileCommand() {
                        path = path,
                        directory = dir,
                        command = cmd
                    });
                });
            } catch (Error e) {
                log.printf ("failed to parse %s: %s\n", ccjson, e.message);
            }
        }

        // analyze compile_commands.json
        foreach (string filename in ctx.get_filenames ()) {
            log.printf ("analyzing args for %s\n", filename);
            CompileCommand? command = cc[filename];
            if (command != null) {
                MatchInfo minfo;
                if (/--pkg[= ](\S+)/.match (command.command, 0, out minfo)) {
                    try {
                        do {
                            ctx.add_package (minfo.fetch (1));
                            log.printf (@"adding package $(minfo.fetch (1))\n");
                        } while (minfo.next ());
                    } catch (Error e) {
                        log.printf (@"regex match error: $(e.message)\n");
                    }
                }

                if (/--vapidir[= ](\S+)/.match (command.command, 0, out minfo)) {
                    try {
                        do {
                            ctx.add_vapidir (minfo.fetch (1));
                            log.printf (@"adding package $(minfo.fetch (1))\n");
                        } while (minfo.next ());
                    } catch (Error e) {
                        log.printf (@"regex match error: $(e.message)\n");
                    }
                }
            }
        }
    }

    void add_vala_files (File dir) throws Error {
        var enumerator = dir.enumerate_children ("standard::*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo info;

        try {
            while ((info = enumerator.next_file (null)) != null) {
                if (info.get_file_type () == FileType.DIRECTORY)
                    add_vala_files (enumerator.get_child (info));
                else {
                    var file = enumerator.get_child (info);
                    string fname = file.get_path ();
                    if (is_source_file (fname)) {
                        try {
                            var doc = new TextDocument (ctx, fname);
                            ctx.add_source_file (doc);
                            log.printf (@"Adding text document: $fname\n");
                        } catch (Error e) {
                            log.printf (@"Failed to create text document: $(e.message)\n");
                        }
                    }
                }
            }
        } catch (Error e) {
            log.printf (@"Error adding files: $(e.message)\n");
        }
    }

    void default_analyze_build_dir (Jsonrpc.Client client, string root_dir) {
        try {
            add_vala_files (File.new_for_path (root_dir));
        } catch (Error e) {
            log.printf (@"Error adding files $(e.message)\n");
        }
    }

    void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var dict = new VariantDict (@params);

        int64 pid;
        dict.lookup ("processId", "x", out pid);

        string? root_path;
        dict.lookup ("rootPath", "s", out root_path);

        string? meson = findFile (root_path, "meson.build");
        if (meson != null) {
            string? ninja = findFile (root_path, "build.ninja");

            if (ninja == null) {
                // TODO: build again
                // ninja = findFile (root_path, "build.ninja");
            }
            
            // test again
            if (ninja != null) {
                log.printf ("Found meson project: %s\nninja: %s\n", meson, ninja);
                meson_analyze_build_dir (client, root_path, Path.get_dirname (ninja));
            } else {
                log.printf ("Found meson.build but not build.ninja: %s\n", meson);
            }
        } else {
            /* if this isn't a Meson project, we should 
             * just take every single file
             */
            log.printf ("No meson project found. Adding all Vala files in %s\n", root_path);
            default_analyze_build_dir (client, root_path);
        }

        cc_analyze (root_path);

        // compile everything ahead of time
        if (ctx.dirty) {
            ctx.check ();
        }

        try {
            client.reply (id, buildDict(
                capabilities: buildDict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Full),
                    definitionProvider: new Variant.boolean (true),
                    completionProvider: buildDict(
                        resolveProvider: new Variant.boolean (false),
                        triggerCharacters: new Variant.strv (new string[] { ".", ">", " ", "(", "[" })
                    )
                )
            ));
        } catch (Error e) {
            log.printf (@"initialize: failed to reply to client: $(e.message)\n");
        }
    }

    string? findFile (string dirname, string target) {
        Dir dir = null;
        try {
            dir = Dir.open (dirname, 0);
        } catch (FileError e) {
            log.printf ("dirname=%s, target=%s, error=%s\n", dirname, target, e.message);
            return null;
        }

        string name;
        while ((name = dir.read_name ()) != null) {
            string path = Path.build_filename (dirname, name);
            if (name == target)
                return path;

            if (FileUtils.test (path, FileTest.IS_DIR)) {
                string r = findFile (path, target);
                if (r != null)
                    return r;
            }
        }
        return null;
    }

    string findCompileCommands (string filename) {
        string r = null, p = filename;
        do {
            r = findFile (p, "compile_commands.json");
            p = Path.get_dirname (p);
        } while (r == null && p != "/" && p != ".");
        return r;
    }

    T? parse_variant<T> (Variant variant) {
        var json = Json.gvariant_serialize(variant);
        return Json.gobject_deserialize(typeof(T), json);
    }

    Variant object_to_variant (Object object) throws Error {
        var json = Json.gobject_serialize (object);
        return Json.gvariant_deserialize (json, null);
    }

    public static size_t get_string_pos (string str, uint lineno, uint charno) {
        int linepos = -1;

        for (uint lno = 0; lno < lineno; ++lno) {
            int pos = str.index_of_char ('\n', linepos + 1);
            if (pos == -1)
                break;
            linepos = pos;
        }

        return linepos+1 + charno;
    }

    void textDocumentDidOpen (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string uri          = (string) document.lookup_value ("uri",        VariantType.STRING);
        string languageId   = (string) document.lookup_value ("languageId", VariantType.STRING);
        string fileContents = (string) document.lookup_value ("text",       VariantType.STRING);

        if (languageId != "vala") {
            warning (@"$languageId file sent to vala language server");
            return;
        }

        string filename;
        try {
            filename = Filename.from_uri (uri);
        } catch (Error e) {
            log.printf (@"failed to convert URI $uri to filename: $(e.message)\n");
            return;
        }

        if (ctx.get_source_file (uri) == null) {
            TextDocument doc;
            try {
                doc = new TextDocument (ctx, filename, fileContents);
            } catch (Error e) {
                log.printf (@"failed to create text document: $(e.message)\n");
                return;
            }

            ctx.add_source_file (doc);
        } else {
            ctx.get_source_file (uri).file.content = fileContents;
        }

        // compile everything if context is dirty
        if (ctx.dirty) {
            ctx.check ();
        }

        publishDiagnostics (client, uri);
    }

    void textDocumentDidChange (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int) document.lookup_value ("version", VariantType.INT64);
        TextDocument? source = ctx.get_source_file (uri);

        if (source == null) {
            log.printf (@"no document found for $uri\n");
            return;
        }

        if (source.file.content == null) {
            char* ptr = source.file.get_mapped_contents ();

            if (ptr == null) {
                log.printf (@"$uri: get_mapped_contents() failed\n");
            }
            source.file.content = (string) ptr;

            if (source.file.content == null) {
                log.printf (@"$uri: content is NULL\n");
                return;
            }
        }

        if (source.version > version) {
            log.printf (@"rejecting outdated version of $uri\n");
            return;
        }

        source.version = version;

        var iter = changes.iterator ();
        Variant? elem = null;
        var sb = new StringBuilder (source.file.content);
        while ((elem = iter.next_value ()) != null) {
            var changeEvent = parse_variant<TextDocumentContentChangeEvent> (elem);

            if (changeEvent.range == null && changeEvent.rangeLength == null) {
                sb.assign (changeEvent.text);
            } else {
                var start = changeEvent.range.start;
                size_t pos = get_string_pos (sb.str, start.line, start.character);
                sb.overwrite (pos, changeEvent.text);
            }
        }
        source.file.content = sb.str;

        // if we're at this point, the file is present in the context
        // any change we make invalidates the context
        ctx.invalidate ();

        // we have to update everything
        ctx.check ();

        publishDiagnostics (client);
    }

    void publishDiagnostics (Jsonrpc.Client client, string? doc_uri = null) {
        Collection<TextDocument> docs;
        TextDocument? doc = doc_uri == null ? null : ctx.get_source_file (doc_uri);

        if (doc != null) {
            docs = new ArrayList<TextDocument>();
            docs.add (doc);
        } else {
            docs = ctx.get_source_files ();
        }

        foreach (var document in docs) {
            var source = document.file;
            string uri = document.uri;
            if (ctx.report.get_errors () + ctx.report.get_warnings () > 0) {
                var array = new Json.Array ();

                ctx.report.errorlist.foreach (err => {
                    if (err.loc.file != source)
                        return;

                    var diag = new Diagnostic () {
                        range = new Range () {
                            start = new Position () {
                                line = err.loc.begin.line - 1,
                                character = err.loc.begin.column - 1
                            },
                            end = new Position () {
                                line = err.loc.end.line - 1,
                                character = err.loc.end.column
                            }
                        },
                        severity = DiagnosticSeverity.Error,
                        message = err.message
                    };

                    var node = Json.gobject_serialize (diag);
                    array.add_element (node);
                });

                ctx.report.warnlist.foreach (err => {
                    if (err.loc.file != source)
                        return;

                    var diag = new Diagnostic () {
                        range = new Range () {
                            start = new Position () {
                                line = err.loc.begin.line - 1,
                                character = err.loc.begin.column - 1
                            },
                            end = new Position () {
                                line = err.loc.end.line - 1,
                                character = err.loc.end.column
                            }
                        },
                        severity = DiagnosticSeverity.Warning,
                        message = err.message
                    };

                    var node = Json.gobject_serialize (diag);
                    array.add_element (node);
                });

                Variant result;
                try {
                    result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
                } catch (Error e) {
                    log.printf (@"failed to create diagnostics: $(e.message)");
                    continue;
                }

                try {
                    client.send_notification ("textDocument/publishDiagnostics", buildDict(
                        uri: new Variant.string (uri),
                        diagnostics: result
                    ));
                } catch (Error e) {
                    log.printf (@"publishDiagnostics: failed to notify client: $(e.message)\n");
                    continue;
                }

                log.printf (@"textDocument/publishDiagnostics: $uri\n");
            }
        }
    }

    void textDocumentDefinition (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant <LanguageServer.TextDocumentPositionParams> (@params);
        log.printf ("get definition in %s at %u,%u\n", p.textDocument.uri,
            p.position.line, p.position.character);
        var file = ctx.get_source_file (p.textDocument.uri).file;
        var fs = new FindSymbol (file, p.position.to_libvala ());

        if (fs.result.size == 0) {
            reply_to_client (method, client, id, buildDict(null));
            return;
        }

        Vala.CodeNode best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else if (best.source_reference.begin.column <= node.source_reference.begin.column &&
                       node.source_reference.end.column <= best.source_reference.end.column) {
                best = node;
            }
        }
        {
            var sr = best.source_reference;
            var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
            var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
            string contents = file.content [from:to];
            log.printf ("Got node: %s @ %s = %s\n", best.type_name, sr.to_string(), contents);
        }

        if (best is Vala.MemberAccess) {
            best = ((Vala.MemberAccess)best).symbol_reference;
        }

        string uri = null;
        foreach (var sourcefile in ctx.get_source_files ()) {
            if (best.source_reference.file == sourcefile.file) {
                uri = sourcefile.uri;
                break;
            }
        }
        if (uri == null) {
            log.printf ("error: couldn't find source file for %s\n", best.source_reference.file.filename);
            reply_to_client (method, client, id, buildDict (null));
            return;
        }

        try {
            client.reply (id, object_to_variant (new LanguageServer.Location () {
                uri = uri,
                range = new Range () {
                    start = new Position () {
                        line = best.source_reference.begin.line - 1,
                        character = best.source_reference.begin.column - 1
                    },
                    end = new Position () {
                        line = best.source_reference.end.line - 1,
                        character = best.source_reference.end.column
                    }
                }
            }));
        } catch (Error e) {
            log.printf ("Failed to reply to client.\n");
        }
    }

    void add_completions_for_type (Vala.TypeSymbol type, Gee.ArrayList<CompletionItem> completions) {
        if (type is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_type = type as Vala.ObjectTypeSymbol;

            log.printf("completion: type is object\n");

            foreach (var method_sym in object_type.get_methods ()) {
                if (method_sym.name == ".new")
                    continue;
                completions.add (new CompletionItem () {
                    label = method_sym.name,
                    kind = CompletionItemKind.Method
                });
            }

            foreach (var signal_sym in object_type.get_signals ())
                completions.add (new CompletionItem () {
                    label = signal_sym.name,
                    kind = CompletionItemKind.Method
                });

            foreach (var prop_sym in object_type.get_properties ())
                completions.add (new CompletionItem () {
                    label = prop_sym.name,
                    kind = CompletionItemKind.Property
                });

            foreach (var constant_sym in object_type.get_constants ()) {
                completions.add (new CompletionItem () {
                    label = constant_sym.name,
                    kind = CompletionItemKind.Value
                });
            }

            foreach (var field_sym in object_type.get_fields ())
                completions.add (new CompletionItem () {
                    label = field_sym.name,
                    kind = CompletionItemKind.Field
                });

            // get inner types
            foreach (var class_sym in object_type.get_classes ())
                completions.add (new CompletionItem () {
                    label = class_sym.name,
                    kind = CompletionItemKind.Class
                });

            foreach (var struct_sym in object_type.get_structs ())
                completions.add (new CompletionItem () {
                    label = struct_sym.name,
                    kind = CompletionItemKind.Class
                });

            foreach (var enum_sym in object_type.get_enums ())
                completions.add (new CompletionItem () {
                    label = enum_sym.name,
                    kind = CompletionItemKind.Enum
                });

            foreach (var delegate_sym in object_type.get_delegates ())
                completions.add (new CompletionItem () {
                    label = delegate_sym.name,
                    kind = CompletionItemKind.Class
                });

            log.printf(@"completions.size = $(completions.size)\n");
        } else if (type is Vala.Enum) {
            /**
             * Complete members of this enum, such as the values, methods,
             * and constants.
             */
            var enum_type = type as Vala.Enum;

            foreach (var value_sym in enum_type.get_values ())
                completions.add (new CompletionItem () {
                    label = value_sym.name,
                    kind = CompletionItemKind.Value
                });

            foreach (var method_sym in enum_type.get_methods ())
                completions.add (new CompletionItem () {
                    label = method_sym.name,
                    kind = CompletionItemKind.Method
                });

            foreach (var constant_sym in enum_type.get_constants ())
                completions.add (new CompletionItem () {
                    label = constant_sym.name,
                    kind = CompletionItemKind.Field /* FIXME: is this appropriate? */
                });
        } else if (type is Vala.ErrorDomain) {
            /**
             * Get all the members of the error domain, such as the error
             * codes and the methods.
             */
            var errdomain_type = type as Vala.ErrorDomain;

            foreach (var code_sym in errdomain_type.get_codes ())
                completions.add (new CompletionItem () {
                    label = code_sym.name,
                    kind = CompletionItemKind.Value
                });

            foreach (var method_sym in errdomain_type.get_codes ())
                completions.add (new CompletionItem () {
                    label = method_sym.name,
                    kind = CompletionItemKind.Method
                });
        } else if (type is Vala.Struct) {
            /**
             * Gets all of the members of the struct.
             */
            var struct_type = type as Vala.Struct;

            foreach (var constant_sym in struct_type.get_constants ())
                completions.add (new CompletionItem () {
                    label = constant_sym.name,
                    kind = CompletionItemKind.Value
                });

            foreach (var field_sym in struct_type.get_fields ())
                completions.add (new CompletionItem () {
                    label = field_sym.name,
                    kind = CompletionItemKind.Field
                });

            foreach (var method_sym in struct_type.get_methods ())
                completions.add (new CompletionItem () {
                    label = method_sym.name,
                    kind = CompletionItemKind.Method
                });

            foreach (var prop_sym in struct_type.get_properties ())
                completions.add (new CompletionItem () {
                    label = prop_sym.name,
                    kind = CompletionItemKind.Property
                });
        } else if (type is Vala.Delegate) {
            var delg_type = type as Vala.Delegate;

            log.printf (@"delegate type \n");
        } else {
            log.printf (@"unknown type node $(type).\n");
        }
    }

    Vala.TypeSymbol? get_typesymbol_member (Vala.TypeSymbol type, string member_name) {
        if (type is Vala.ObjectTypeSymbol) {
            var object_type = type as Vala.ObjectTypeSymbol;

            foreach (var constant_sym in object_type.get_constants ())
                if (constant_sym.name == member_name && constant_sym.type_reference != null)
                    return constant_sym.type_reference.data_type;

            foreach (var field_sym in object_type.get_fields ())
                if (field_sym.name == member_name && field_sym.variable_type != null)
                    return field_sym.variable_type.data_type;
            
            foreach (var prop_sym in object_type.get_properties ())
                if (prop_sym.name == member_name && prop_sym.property_type != null)
                    return prop_sym.property_type.data_type;

            foreach (var class_sym in object_type.get_classes ())
                if (class_sym.name == member_name)
                    return class_sym;
            
            foreach (var struct_sym in object_type.get_structs ())
                if (struct_sym.name == member_name)
                    return struct_sym;
            
            foreach (var enum_sym in object_type.get_enums ())
                if (enum_sym.name == member_name)
                    return enum_sym;

        } else if (type is Vala.Enum) {
            var enum_type = type as Vala.Enum;

            foreach (var value_sym in enum_type.get_values ())
                if (value_sym.name == member_name && value_sym.type_reference != null)
                    return value_sym.type_reference.data_type;
        } else if (type is Vala.ErrorDomain) {
            var errdomain_type = type as Vala.ErrorDomain;

            foreach (var code_sym in errdomain_type.get_codes ())
                if (code_sym.name == member_name)
                    return code_sym;
        } else if (type is Vala.Struct) {
            var struct_type = type as Vala.Struct;

            foreach (var field_sym in struct_type.get_fields ())
                if (field_sym.name == member_name && field_sym.variable_type != null)
                    return field_sym.variable_type.data_type;
            
            foreach (var const_sym in struct_type.get_constants ())
                if (const_sym.name == member_name && const_sym.type_reference != null)
                    return const_sym.type_reference.data_type;
            
            foreach (var prop_sym in struct_type.get_properties ())
                if (prop_sym.name == member_name && prop_sym.property_type != null)
                    return prop_sym.property_type.data_type;
        }

        return null;
    }

    Vala.TypeSymbol? get_type_symbol (Vala.DataType dtype) {
        if (dtype is Vala.InterfaceType)
            return (dtype as Vala.InterfaceType).interface_symbol;
        if (dtype is Vala.ClassType)
            return (dtype as Vala.ClassType).class_symbol;
        if (dtype is Vala.ValueType)
            return (dtype as Vala.ValueType).type_symbol;
        if (dtype is Vala.ObjectType)
            return (dtype as Vala.ObjectType).type_symbol;
        if (dtype is Vala.ErrorType)
            return (dtype as Vala.ErrorType).error_domain;
        // TODO: array type
        if (dtype is Vala.FieldPrototype)
            return get_type_symbol ((dtype as Vala.FieldPrototype).field_symbol.variable_type);
        if (dtype != null)
            log.printf ("dtype is something else: %s\n", dtype.to_string ());
        if (dtype is Vala.UnresolvedType)
            log.printf ("dtype is UnresolvedType\n");
        if (dtype is Vala.ReferenceType)
            log.printf ("dtype is ReferenceType\n");
        if (dtype is Vala.InvalidType)
            log.printf ("dtype is InvalidType\n");
        if (dtype is Vala.VoidType)
            log.printf ("dtype is VoidType\n");
        if (dtype is Vala.NullType)
            log.printf ("dtype is NullType\n");
        return null;
    }

    void add_member_access_completions (Vala.CodeNode best, Gee.ArrayList<CompletionItem> completions, string token) {
        if (best is Vala.MemberAccess) {
            var ma = best as Vala.MemberAccess;
            Vala.TypeSymbol type;

            log.printf ("symbol_reference is %s\n", ma.symbol_reference.to_string ());
            log.printf ("value_type is %s, formal_value_type is %s, target_type is %s, formal_target_type is %s\n",
                    ma.value_type.to_string (), 
                    ma.formal_value_type != null ? ma.formal_value_type.to_string () : null, 
                    ma.target_type.to_string (),
                    ma.formal_target_type != null ? ma.formal_target_type.to_string () : null);
            log.printf ("inner is %s\n", ma.inner != null ? ma.inner.to_string () : null);

            type = get_type_symbol (ma.value_type);

            if (type == null) {
                // This may be the last token in a failed parse.
                // It has no type information, but we can try searching
                // through the scope hierarchy for the symbol.
            } else if (ma.formal_value_type == null) {
                // this is likely a member access with an implicit 'this'
                var ts = this.get_typesymbol_member (type, token);
                log.printf ("get_typesymbol_member (%s, %s) = %s\n", 
                    type.to_string (), token, ts.to_string ());
                if (ts!= null)
                    type = ts;
            }

            log.printf ("type is %s", type.to_string ());
            
            if (type != null)
                add_completions_for_type (type, completions);
        } else if (best is Vala.PointerIndirection) {
            var pi = best as Vala.PointerIndirection;
            Vala.TypeSymbol type;

            type = pi.inner.value_type.data_type;
            log.printf ("type is %s", type.to_string ());

            if (type != null)
                add_completions_for_type (type, completions);
        } else if (best is Vala.Expression) {
            Vala.TypeSymbol type;
            var expr = best as Vala.Expression;

            type = get_type_symbol (expr.value_type);
            log.printf ("type is %s\n", type.to_string ());

            if (type != null)
                add_completions_for_type (type, completions);
        } else if (best is Vala.Variable) {
            Vala.TypeSymbol type;
            var pram = best as Vala.Variable;

            type = get_type_symbol (pram.variable_type);
            log.printf ("type is %s\n", type.to_string ());

            if (type != null)
                add_completions_for_type (type, completions);
        } else if (best is Vala.TypeSymbol) {
            add_completions_for_type (best as Vala.TypeSymbol, completions);
        } else {
            log.printf (@"some other type of expression: $(best.type_name) @ $(best)\n");
        }
    }

    void textDocumentCompletion (Jsonrpc.Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant <LanguageServer.TextDocumentPositionParams> (@params);
        log.printf ("executing completion in %s at %u,%u\n", p.textDocument.uri,
            p.position.line, p.position.character);
        var doc = ctx.get_source_file (p.textDocument.uri);
        if (doc == null) {
            log.printf (@"error: unrecognized text file '$(p.textDocument.uri)'");
            reply_to_client (method, client, id, buildDict(null));
            return;
        }

        var pos = p.position.to_libvala ();
        long loc = (long) Server.get_string_pos (doc.file.content, p.position.line, p.position.character-1);
        unichar c = doc.file.content.get_char (loc);
        Vls.CompletionType? completion_type = null;

        // determine the type of autocompletion we have to do
        if (c == '.') { // member access
            pos.character -= 1;
            completion_type = CompletionType.MemberAccess;
        } else if (c == '>') { // pointer access
            if (loc > 0 && doc.file.content.get_char (loc-1) == '-') {
                loc -= 1;
                pos.character -= 2;
                completion_type = CompletionType.MemberAccess;
            } else {
                log.printf ("ignoring '>' without preceding '-'\n");
                reply_to_client (method, client, id, buildDict (null));
                return;
            }
        } else {
            log.printf ("TODO for '%s'\n", c.to_string ());
            reply_to_client (method, client, id, buildDict (null));
            return;
        }

        Finder<Vala.CodeNode> fs = new FindSymbol (doc.file, pos); 

        Vala.CodeNode? best = null;

        log.printf (@"completion: found $(fs.result.size) symbols\n");

        if (fs.result.size == 0) {
            // try parsing a  
            long end = loc-1;
            long start = end;

            c = doc.file.content.get_char (end);
            while (c.isalnum () && start > 0) {
                start--;
                c = doc.file.content.get_char (start);
            }

            start++;

            string token = doc.file.content [start:end+1];

            log.printf ("found token '%s' from %ld to %ld\n", token, start, end);

            var fsc = new FindScope (doc.file, pos);

            log.printf ("found %d scopes\n", fsc.result.size);

            foreach (var scope in fsc.result) {
                for (var pscope = scope; pscope != null; pscope = pscope.parent_scope) {
                    var symtab = pscope.get_symbol_table ();

                    if (symtab == null) {
                        log.printf ("scope has empty symbol table\n");
                        continue;
                    }

                    foreach (var key in symtab.get_keys ()) {
                        if (key == token) {
                            var node = symtab [key];
                            if (best == null)
                                best = node;
                            else if (best.source_reference.begin.column <= node.source_reference.begin.column
                                && node.source_reference.end.column <= best.source_reference.end.column)
                                best = node;
                        }
                    }
                }
            }

            if (best == null) {
                log.printf ("no matching symbol found for token\n");
                fs = new FindToken (doc.file, pos, token);
            } else
                log.printf ("found matching symbol: %s\n", best.to_string ());
        }

        // check again if [fs] changed
        
        if (best == null && fs.result.size == 0) {
            log.printf ("no other results found\n");
            reply_to_client (method, client, id, buildDict(null));
            return;
        } else {
            foreach (var node in fs.result) {
                if (best == null) {
                    best = node;
                } else if (best.source_reference.begin.column <= node.source_reference.begin.column &&
                        node.source_reference.end.column <= best.source_reference.end.column) {
                    best = node;
                }
            }
        }

        string token;
        {
            var sr = best.source_reference;
            var from = (long)Server.get_string_pos (doc.file.content, sr.begin.line-1, sr.begin.column-1);
            var to = (long)Server.get_string_pos (doc.file.content, sr.end.line-1, sr.end.column);
            token = doc.file.content [from:to];
            log.printf ("Got node: %s @ %s = %s\n", best.type_name, sr.to_string(), token);
        }

        var completions = new Gee.ArrayList<CompletionItem> ();
        var completions_variants = new ArrayList<Variant>();

        add_member_access_completions (best, completions, token);

        foreach (var obj in completions) {
            try {
                completions_variants.add (object_to_variant (obj));
            } catch (Error e) {
                log.printf ("%s: Error: failed to convert object to variant.\n", method);
            }
        }

        log.printf (@"$method: showing completions for $(p.textDocument.uri)...\n");
        reply_to_client (method, client, id, 
            new Variant.array (VariantType.VARDICT, completions_variants.to_array ()));
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        ctx.clear ();
        reply_to_client (method, client, id, buildDict(null));
        log.printf ("shutting down...\n");
    }

    void exit (Jsonrpc.Client client, Variant @params) {
        loop.quit ();
    }
}

void main () {
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
}
