/**
 * Defines how the host (editor) should sync document changes to the language server.
 */
[CCode (default_value = "LANGUAGE_SERVER_TEXT_DOCUMENT_SYNC_KIND_Unset")]
enum LanguageServer.TextDocumentSyncKind {
	Unset = -1,
	/**
	 * Documents should not be synced at all.
	 */
	None = 0,
	/**
	 * Documents are synced by always sending the full content of the document.
	 */
	Full = 1,
	/**
	 * Documents are synced by sending the full content on open. After that only incremental
	 * updates to the document are sent.
	 */
	Incremental = 2
}

enum LanguageServer.DiagnosticSeverity {
	Unset = 0,
	/**
	 * Reports an error.
	 */
	Error = 1,
	/**
	 * Reports a warning.
	 */
	Warning = 2,
	/**
	 * Reports an information.
	 */
	Information = 3,
	/**
	 * Reports a hint.
	 */
	Hint = 4
}

class LanguageServer.CompletionOptions : Object {
	/**
	 * The server provides support to resolve additional information for a completion item.
	 */
	public bool resolveProvider			{ get; set; }
	/**
	 * The characters that trigger completion automatically.
	 */
	public string[]? triggerCharacters	{ get; set; }
}

class LanguageServer.Position : Object {
	/**
	 * Line position in a document (zero-based).
	 */
	public uint line { get; set; default = -1; }

	/**
	 * Character offset on a line in a document (zero-based). Assuming that the line is
	 * represented as a string, the `character` value represents the gap between the
	 * `character` and `character + 1`.
	 *
	 * If the character value is greater than the line length it defaults back to the
	 * line length.
	 */
	public uint character { get; set; default = -1; }

	public LanguageServer.Position to_libvala () {
		return new Position () {
			line = this.line + 1,
			character = this.character
		};
	}
}

class LanguageServer.Range : Object {
	/**
	 * The range's start position.
	 */
	public Position start { get; set; }

	/**
	 * The range's end position.
	 */
	public Position end { get; set; }
}

class LanguageServer.Diagnostic : Object {
	/**
	 * The range at which the message applies.
	 */
	public Range range { get; set; }

	/**
	 * The diagnostic's severity. Can be omitted. If omitted it is up to the
	 * client to interpret diagnostics as error, warning, info or hint.
	 */
	public DiagnosticSeverity severity { get; set; }

	/**
	 * The diagnostic's code. Can be omitted.
	 */
	public string? code { get; set; }

	/**
	 * A human-readable string describing the source of this
	 * diagnostic, e.g. 'typescript' or 'super lint'.
	 */
	public string? source { get; set; }

	/**
	 * The diagnostic's message.
	 */
	public string message { get; set; }
}

/**
 * An event describing a change to a text document. If range and rangeLength are omitted
 * the new text is considered to be the full content of the document.
 */
class LanguageServer.TextDocumentContentChangeEvent : Object {
	public Range? range 		{ get; set; }
	public int? rangeLength 	{ get; set; }
	public string text 			{ get; set; }
}

enum LanguageServer.MessageType {
	/**
	 * An error message.
	 */
	Error = 1,
	/**
	 * A warning message.
	 */
	Warning = 2,
	/**
	 * An information message.
	 */
	Info = 3,
	/**
	 * A log message.
	 */
	Log = 4
}

class LanguageServer.TextDocumentIdentifier : Object {
	public string uri { get; set; }
}

class LanguageServer.TextDocumentPositionParams : Object {
	public TextDocumentIdentifier textDocument { get; set; }
	public Position position { get; set; }
}

class LanguageServer.Location : Object {
	public string uri { get; set; }
	public Range range { get; set; }
}

/**
 * The marked string is rendered:
 * - as markdown if it is represented as a string
 * - as code block of the given language if it is represented as a pair of a language and a value
 *
 * The pair of a language and a value is an equivalent to markdown:
 * ```${language}
 * ${value}
 * ```
 */
class LanguageServer.MarkedString : Object {
	public string language 		{ get; construct; }
	public string value 		{ get; construct; }

	public MarkedString (string value, string language = "vala") {
		Object (value: value, language: language);
	}
}

/**
 * The result of a hover request.
 */
class LanguageServer.Hover : Object {
	/**
	 * The hover's content
	 */
	public MarkedString[] contents 	{ get; set; }
	/**
	 * An optional range is a range inside a text document 
	 * that is used to visualize a hover, e.g. by changing the background color.
	 */
	public Range? range 			{ get; set; }

	public Hover (Range range, MarkedString[] contents = new MarkedString[] {}) {
		this.range = range;
		this.contents = contents;
	}
}

/**
 * A textual edit applicable to a text document.
 */
class LanguageServer.TextEdit : Object {
	/**
	 * The range of the text document to be manipulated. To insert
	 * text into a document create a range where start === end.
	 */
	public Range range { get; set; }

	/**
	 * The string to be inserted. For delete operations use an
	 * empty string.
	 */
	public string newText { get; set; }
}

/**
 * The kind of a completion entry.
 */
enum LanguageServer.CompletionItemKind {
	Text = 1,
	Method = 2,
	Function = 3,
	Constructor = 4,
	Field = 5,
	Variable = 6,
	Class = 7,
	Interface = 8,
	Module = 9,
	Property = 10,
	Unit = 11,
	Value = 12,
	Enum = 13,
	Keyword = 14,
	Snippet = 15,
	Color = 16,
	File = 17,
	Reference = 18
}

/**
 * Represents a reference to a command. Provides a title which will be used to
 * represent a command in the UI. Commands are identitifed using a string
 * identifier and the protocol currently doesn't specify a set of well known
 * commands. So executing a command requires some tool extension code.
 */
class LanguageServer.Command : Object {
	/**
	 * Title of the command, like `save`.
	 */
	public string title { get; set; }

	/**
	 * The identifier of the actual command handler.
	 */
	public string command { get; set; }

	/**
	 * Arguments that the command handler should be
	 * invoked with.
	 */
	public Variant[]? arguments { get; set; }
}

class LanguageServer.CompletionItem : Object {
	/**
	 * The label of this completion item. By default
	 * also the text that is inserted when selecting
	 * this completion.
	 */
	public string label { get; set; }

	/**
	 * The kind of this completion item. Based of the kind
	 * an icon is chosen by the editor.
	 */
	public CompletionItemKind kind { get; set; default = CompletionItemKind.Text; }

	/**
	 * A human-readable string with additional information
	 * about this item, like type or symbol information.
	 */
	public string? detail { get; set; }

	/**
	 * A human-readable string that represents a doc-comment.
	 */
	public string? documentation { get; set; }

	/**
	 * A string that shoud be used when comparing this item
	 * with other items. When `falsy` the label is used.
	 */
	public string? sortText { get; set; }

	/**
	 * A string that should be used when filtering a set of
	 * completion items. When `falsy` the label is used.
	 */
	public string? filterText { get; set; }

	/**
	 * A string that should be inserted a document when selecting
	 * this completion. When `falsy` the label is used.
	 */
	public string? insertText { get; set; }

	/**
	 * An edit which is applied to a document when selecting
	 * this completion. When an edit is provided the value of
	 * insertText is ignored.
	 */
	public TextEdit? textEdit { get; set; }

	/**
	 * An optional array of additional text edits that are applied when
	 * selecting this completion. Edits must not overlap with the main edit
	 * nor with themselves.
	 */
	public TextEdit[]? additionalTextEdits { get; set; }

	/**
	 * An optional command that is executed *after* inserting this completion. *Note* that
	 * additional modifications to the current document should be described with the
	 * additionalTextEdits-property.
	 */
	public Command? command { get; set; }

	/**
	 * An data entry field that is preserved on a completion item between
	 * a completion and a completion resolve request.
	 */
	/* public T? data { get; set; } */
}

/**
 * Represents a collection of [completion items](#CompletionItem) to be presented
 * in the editor.
 */
class LanguageServer.CompletionList : Object {
	public bool isIncomplete		{ get; set; }
	public CompletionItem[] items 	{ get; set; }
}