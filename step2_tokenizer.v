module yaml

import ystrconv
import yaml.text_scanner as ts

// See https://yaml.org/spec/1.2/spec.html for all the nitty gritty details

// YamlTokenKind The TextScanner tokens are text centric and quite basic. The 
// tokenizer reads the text tokens and derives YAML tokens. Each YAML token
// will be of a specific kind.
enum YamlTokenKind {
	start_list
	start_object
	close
	key
	value
	new_document
	end_of_document
	tag_url			// Text starting with '!'
	tag_def			// Text starting with '&'
	tag_ref	   		// Text starting with '*'
	tag_directive	// %TAG
} 

// YamlTokenValueType The value of YamlToken can be any of these types.
// The type is auto-detected. Quoted strings always remain strings (without quotes).
// true / false, yes / no are valid boolean values. 0 / 1 are integers. 
type YamlTokenValueType = string | i64 | f64 | bool		// TODO implement bool

fn (typ YamlTokenValueType) str() string {
	return match typ {
		string { typ.str() }
		i64 { typ.str() }
		f64 { typ.str() }
		bool { typ.str() }
	} 
}

fn fix_float_str(v f64) string {
	mut x := v.str() 
	if x.len > 0 && x[x.len - 1] == `.` {
		x += "0"
	}
	return x
}

// format A printable string representation of the value
fn (typ YamlTokenValueType) format() string {
	return match typ {
		string { "\"$typ\"" }
		i64 { typ.str() }
		f64 { fix_float_str(typ) }
		bool { typ.str() }
	} 
}

// YamlToken A YAML token is quite simple. It consists of a token-kind and
// the associated text, if any.
struct YamlToken {
	typ YamlTokenKind
	val YamlTokenValueType
}

// ParentNode This is internal only. While iterating over the text tokens,
// we need to remember a stack with the current parent objects.
struct ParentNode {
	typ string
	indent int
	block bool
}

// YamlTokenizer Iterate over the stream of text tokens provided by TextScanner and 
// transform it into respective YamlToken tokens.
struct YamlTokenizer {
pub:
	fpath string		// file name
	text string			// The full yaml document
	newline string		// The auto-detected newline
	encoding ts.Encodings	// Currently only utf-8 is supported
	debug int

pub mut:
	tokens []YamlToken	// The list of YAML tokens
}

// token_followed_by Return true if the token following the one at position 'i',
// is of type 'typ' or a newline token. 
fn (scanner Scanner) token_followed_by(i int, typ TokenKind) bool {
	j := i + 1
	if j < scanner.tokens.len {
		return scanner.tokens[j].typ == typ
	}
	return typ == TokenKind.newline
}

// is_quoted Test whether 'str' starts and beginns with the quote char provided
[inline]
fn is_quoted(str string, ch byte) bool {
	return str.len > 1 && str[0] == ch && str[str.len - 1] == ch
}

// remove_quotes Remove any optional quotes
fn remove_quotes(str string) string {
	if is_quoted(str, `"`) || is_quoted(str, `'`) {
		return str[1 .. str.len - 1]
	}
	return str
}

// cmp_lowercase Compare two strings ignoring the case. str2 must be
// provided lower case.
fn cmp_lowercase(str1 string, str2 string) bool {
	if str1.len != str2.len { return false }
	for i in 0 .. str1.len {
		mut ch := str1[i]
		if ch >= `A` && ch <= `Z` { ch += 32 }
		if ch != str2[i] { return false }
	}
	return true
}

// to_value_type Analyse the token string and convert it to the respective type.
// Remove any optionally existing quotes for string types
fn to_value_type(str string) YamlTokenValueType {
	if ystrconv.is_int(str) {
		return str.i64()
	} else if ystrconv.is_float(str) {
		return str.f64()
	} else if cmp_lowercase(str, "true") || cmp_lowercase(str, "yes") {
		return true
	} else if cmp_lowercase(str, "false") || cmp_lowercase(str, "no") {
		return false
	}
	return remove_quotes(str)
}

// new_token Create a new token. Dynamically determine the value type. 
// See to_value_type(). 
[inline]
fn new_token(typ YamlTokenKind, val string) YamlToken {
	return YamlToken{ typ: typ, val: to_value_type(val) }
}

// new_empty_token Many token only have a token type, but the token value
// is irrelevant.
[inline]
fn new_empty_token(typ YamlTokenKind) YamlToken {
	return YamlToken{ typ: typ, val: i64(0) }
}

// new_str_token Do not auto-detect the value type, consider the value
// to be a string. Remove any optional quotes.
[inline]
fn new_str_token(typ YamlTokenKind, val string) YamlToken {
	return YamlToken{ typ: typ, val: remove_quotes(val) }
}

// yaml_tokenizer Iterate over the stream of text tokens provided by TextScanner and 
// transform it into respective YamlToken tokens.
fn yaml_tokenizer(fpath string, debug int) ?YamlTokenizer {
	scanner := yaml_scanner(fpath, debug)?

	if scanner.tokens.len == 0 {
		return error("No YAML tokens found")
	}
	
	if debug > 2 { eprintln("------------- yaml_tokenizer") }

	tokens := text_to_yaml_tokens(scanner, debug)?

	mut tokenizer := YamlTokenizer{
		fpath: fpath,
		text: scanner.ts.text,
		newline: scanner.ts.newline,
		encoding: scanner.ts.encoding,
		tokens: tokens,
		debug: debug
	}

	return tokenizer
}

// text_to_yaml_tokens The main tokenizer function: convert string like tokens
// into proper YAML tokens
fn text_to_yaml_tokens(scanner &Scanner, debug int) ?[]YamlToken {

	mut tokens := []YamlToken{}
	mut parents := []ParentNode{}	// This is internal only, during transformation

	for i, t in scanner.tokens {
		if debug > 2 { eprintln("col: $t.column, typ: $t.typ, val: '$t.val'") }
		if parents.len > 0 && parents.last().block == true {
			if t.typ == TokenKind.xstr {
				if scanner.token_followed_by(i, TokenKind.colon) {
					tokens << new_token(YamlTokenKind.key, t.val)
				} else {
					tokens << new_token(YamlTokenKind.value, t.val)
				}
			} else if t.typ == TokenKind.rabr {
				parents.pop()
				tokens << new_empty_token(YamlTokenKind.close)
			} else if t.typ == TokenKind.rcbr {
				parents.pop()
				tokens << new_empty_token(YamlTokenKind.close)
			} else if t.typ == TokenKind.comma && parents.last().typ == "list" {
				// ignore
			}
			continue
		} 

		for parents.len > 0 && parents.last().indent > t.column {
			parents.pop()
			tokens << new_empty_token(YamlTokenKind.close)
		}

		if parents.len == 0 || parents.last().indent < t.column {
			if t.typ == TokenKind.hyphen {
				parents << ParentNode{ typ: "list", indent: t.column, block: false }
				tokens << new_empty_token(YamlTokenKind.start_list)
			} else if t.typ == TokenKind.xstr && scanner.token_followed_by(i, TokenKind.colon) {
				parents << ParentNode{ typ: "object", indent: t.column, block: false }
				tokens << new_empty_token(YamlTokenKind.start_object)
			}
		}

		if t.typ == TokenKind.xstr && scanner.token_followed_by(i, TokenKind.newline) {
			tokens << new_token(YamlTokenKind.value, t.val)
		} else if t.typ == TokenKind.xstr && scanner.token_followed_by(i, TokenKind.colon) {
			// TODO There is a bug in V. mut ar []int in combination with ar.last() generates wrong C code
			// if tokens.len > 0 && tokens.last().typ == YamlTokenKind.key {
			if tokens.len > 0 && tokens[tokens.len - 1].typ == YamlTokenKind.key {
				if parents.last().indent == t.column {
					// Key with null value
					tokens << new_str_token(YamlTokenKind.value, "")
				}
			}
			tokens << YamlToken{ typ: YamlTokenKind.key, val: to_value_type(t.val) }
		} else if t.typ == TokenKind.labr {
			parents << ParentNode{ typ: "list", indent: t.column, block: true }
			tokens << new_empty_token(YamlTokenKind.start_list)
		} else if t.typ == TokenKind.lcbr {
			parents << ParentNode{ typ: "object", indent: t.column, block: true }
			tokens << new_empty_token(YamlTokenKind.start_object)
		} else if t.typ == TokenKind.question_mark {
			return error("complex mapping key: NOT SUPPORTED")
		} else if t.typ == TokenKind.tag_ref {
			tokens << new_token(YamlTokenKind.tag_ref, t.val)
		} else if t.typ == TokenKind.tag_def {
			tokens << new_token(YamlTokenKind.tag_def, t.val)
		} else if t.typ == TokenKind.end_of_document {
			for parents.len > 0 {
				parents.pop()
				tokens << new_empty_token(YamlTokenKind.close)
			}
			tokens << new_empty_token(YamlTokenKind.end_of_document)
		} else if t.typ == TokenKind.document {
			if parents.len > 0 {
				for parents.len > 0 {
					parents.pop()
					tokens << new_empty_token(YamlTokenKind.close)
				}
				tokens << new_empty_token(YamlTokenKind.end_of_document)
			}
			tokens << new_empty_token(YamlTokenKind.new_document)
		}
	}

	if parents.len > 0 {
		for parents.len > 0 {
			parents.pop()
			tokens << new_empty_token(YamlTokenKind.close)
		}
		tokens << new_empty_token(YamlTokenKind.end_of_document)
	}

	return tokens
}

/* See ex 2.11: we do not support complex mapping key, such as 

? - Detroit Tigers
  - Chicago cubs
:
  - 2001-07-23

? [ New York Yankees,
    Atlanta Braves ]
: [ 2001-07-02, 2001-08-12,
    2001-08-14 ]
*/