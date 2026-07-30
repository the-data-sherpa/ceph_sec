package shell

import "core:strings"

// Tokeniser.
//
// Shell-like but deliberately small: whitespace splits, single and double
// quotes group, backslash escapes the next character inside double quotes and
// outside them. No expansion, no globbing, no substitution -- the game never
// needs them, and every feature added here is a feature that has to behave
// correctly under adversarial input forever.

MAX_TOKENS :: 64

Lex_Error :: enum {
	None,
	Unterminated_Quote,
	Too_Many_Tokens,
}

// Tokens are freshly allocated, so callers own them and quoting/escaping can
// change a token's contents rather than merely its bounds.
lex :: proc(
	src: string,
	allocator := context.allocator,
) -> (
	tokens: []string,
	err: Lex_Error,
) {
	out := make([dynamic]string, 0, 8, allocator)
	sb := strings.builder_make(allocator)
	defer strings.builder_destroy(&sb)

	has_token := false // distinguishes "" (a real empty token) from no token
	quote: u8 = 0      // 0, '\'' or '"'

	i := 0
	for i < len(src) {
		c := src[i]

		switch {
		case quote == 0 && (c == ' ' || c == '\t'):
			if has_token {
				append(&out, strings.clone(strings.to_string(sb), allocator))
				strings.builder_reset(&sb)
				has_token = false
			}

		case quote == 0 && (c == '\'' || c == '"'):
			quote = c
			has_token = true // `""` must survive as an empty argument

		case quote != 0 && c == quote:
			quote = 0

		case c == '\\' && quote != '\'':
			// Backslash is literal inside single quotes, an escape everywhere
			// else. A trailing backslash is itself.
			i += 1
			if i < len(src) {
				strings.write_byte(&sb, src[i])
				has_token = true
			} else {
				strings.write_byte(&sb, '\\')
				has_token = true
			}

		case:
			strings.write_byte(&sb, c)
			has_token = true
		}

		i += 1
	}

	if quote != 0 {
		return nil, .Unterminated_Quote
	}
	if has_token {
		append(&out, strings.clone(strings.to_string(sb), allocator))
	}

	if len(out) > MAX_TOKENS {
		return nil, .Too_Many_Tokens
	}
	return out[:], .None
}
