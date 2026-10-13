#!/usr/bin/env python3
"""Conservative Spotfire expression to Sigma formula translation.

The translator accepts a deliberately small grammar.  Unknown tokens,
functions, arities, and window navigators return a structured unsupported
result instead of passing source text through as if it were valid Sigma.
"""
from dataclasses import dataclass
import json
import re


class Unsupported(Exception):
    """A fail-closed translation error with a stable warning identifier."""

    def __init__(self, message, warning_id="SPOTFIRE-EXPR-UNSUPPORTED"):
        super().__init__(message)
        self.warning_id = warning_id


@dataclass(frozen=True)
class TranslationResult:
    supported: bool
    formula: str = None
    kind: str = None
    references: tuple = ()
    warning_id: str = None
    reason: str = None

    def as_dict(self):
        value = {
            "supported": self.supported,
            "formula": self.formula,
            "kind": self.kind,
            "references": list(self.references),
        }
        if self.warning_id:
            value["warning_id"] = self.warning_id
        if self.reason:
            value["reason"] = self.reason
        return value


@dataclass(frozen=True)
class _Token:
    kind: str
    value: str
    position: int


@dataclass(frozen=True)
class _Node:
    text: str
    aggregate: bool = False
    references: frozenset = frozenset()


# name -> (Sigma name, minimum arguments, maximum arguments, aggregate)
_FUNCTIONS = {
    # Aggregates.
    "sum": ("Sum", 1, 1, True),
    "avg": ("Avg", 1, 1, True),
    "average": ("Avg", 1, 1, True),
    "count": ("Count", 0, 1, True),
    "uniquecount": ("CountDistinct", 1, 1, True),
    "countdistinct": ("CountDistinct", 1, 1, True),
    "min": ("Min", 1, 1, True),
    "max": ("Max", 1, 1, True),
    "median": ("Median", 1, 1, True),
    "stddev": ("StdDev", 1, 1, True),
    "stdev": ("StdDev", 1, 1, True),
    "variance": ("Variance", 1, 1, True),
    "var": ("Variance", 1, 1, True),
    "varp": ("VariancePop", 1, 1, True),
    "percentile": ("Percentile", 2, 2, True),
    # Conditional/null handling.
    "if": ("If", 3, 3, False),
    "isnull": ("IsNull", 1, 1, False),
    "sn": ("Coalesce", 2, 2, False),
    "ifnull": ("Coalesce", 2, 2, False),
    "coalesce": ("Coalesce", 2, None, False),
    # Dates. These retain the argument order shared by Spotfire and Sigma.
    "date": ("Date", 1, 3, False),
    "dateadd": ("DateAdd", 3, 3, False),
    "datediff": ("DateDiff", 3, 3, False),
    "datepart": ("DatePart", 2, 2, False),
    "datetrunc": ("DateTrunc", 2, 2, False),
    "year": ("Year", 1, 1, False),
    "month": ("Month", 1, 1, False),
    "day": ("Day", 1, 1, False),
    "hour": ("Hour", 1, 1, False),
    "minute": ("Minute", 1, 1, False),
    "second": ("Second", 1, 1, False),
    "today": ("Today", 0, 0, False),
    "now": ("Now", 0, 0, False),
    # Strings.
    "concatenate": ("Concat", 2, None, False),
    "concat": ("Concat", 2, None, False),
    "upper": ("Upper", 1, 1, False),
    "ucase": ("Upper", 1, 1, False),
    "lower": ("Lower", 1, 1, False),
    "lcase": ("Lower", 1, 1, False),
    "trim": ("Trim", 1, 1, False),
    "len": ("Len", 1, 1, False),
    "length": ("Len", 1, 1, False),
    "left": ("Left", 2, 2, False),
    "right": ("Right", 2, 2, False),
    "substitute": ("Replace", 3, 3, False),
    "replace": ("Replace", 3, 3, False),
    # Numeric scalar functions.
    "abs": ("Abs", 1, 1, False),
    "ceiling": ("Ceiling", 1, 1, False),
    "floor": ("Floor", 1, 1, False),
    "round": ("Round", 1, 2, False),
    "sqrt": ("Sqrt", 1, 1, False),
    "power": ("Power", 2, 2, False),
    "mod": ("Mod", 2, 2, False),
}


def _tokenize(source):
    tokens = []
    index = 0
    length = len(source)
    while index < length:
        char = source[index]
        if char.isspace():
            index += 1
            continue
        if char == "[":
            start = index
            index += 1
            value = []
            while index < length:
                if source[index] == "]":
                    if index + 1 < length and source[index + 1] == "]":
                        value.append("]")
                        index += 2
                        continue
                    index += 1
                    break
                value.append(source[index])
                index += 1
            else:
                raise Unsupported(
                    "unterminated Spotfire column reference at character %d" % start,
                    "SPOTFIRE-EXPR-COLUMN-UNTERMINATED",
                )
            name = "".join(value).strip()
            if not name:
                raise Unsupported(
                    "empty Spotfire column reference",
                    "SPOTFIRE-EXPR-COLUMN-EMPTY",
                )
            tokens.append(_Token("COLUMN", name, start))
            continue
        if char in ('"', "'"):
            quote = char
            start = index
            index += 1
            value = []
            while index < length:
                current = source[index]
                if current == quote:
                    if index + 1 < length and source[index + 1] == quote:
                        value.append(quote)
                        index += 2
                        continue
                    index += 1
                    break
                if current == "\\" and index + 1 < length:
                    escapes = {"n": "\n", "r": "\r", "t": "\t"}
                    following = source[index + 1]
                    value.append(escapes.get(following, following))
                    index += 2
                    continue
                value.append(current)
                index += 1
            else:
                raise Unsupported(
                    "unterminated string literal at character %d" % start,
                    "SPOTFIRE-EXPR-STRING-UNTERMINATED",
                )
            tokens.append(_Token("STRING", "".join(value), start))
            continue
        number = re.match(r"(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?", source[index:])
        if number:
            value = number.group(0)
            tokens.append(_Token("NUMBER", value, index))
            index += len(value)
            continue
        identifier = re.match(r"[A-Za-z_][A-Za-z0-9_]*", source[index:])
        if identifier:
            value = identifier.group(0)
            tokens.append(_Token("IDENT", value, index))
            index += len(value)
            continue
        pair = source[index:index + 2]
        if pair in ("<=", ">=", "<>", "!="):
            tokens.append(_Token("OP", pair, index))
            index += 2
            continue
        if char in "+-*/%^=&<>":
            tokens.append(_Token("OP", char, index))
            index += 1
            continue
        if char == "(":
            tokens.append(_Token("LPAREN", char, index))
            index += 1
            continue
        if char == ")":
            tokens.append(_Token("RPAREN", char, index))
            index += 1
            continue
        if char == ",":
            tokens.append(_Token("COMMA", char, index))
            index += 1
            continue
        if char == ".":
            tokens.append(_Token("DOT", char, index))
            index += 1
            continue
        raise Unsupported(
            "unsupported token %r at character %d" % (char, index),
            "SPOTFIRE-EXPR-TOKEN-UNSUPPORTED",
        )
    tokens.append(_Token("EOF", "", length))
    return tokens


class _Parser:
    def __init__(self, source):
        self.source = source
        self.tokens = _tokenize(source)
        self.index = 0

    @property
    def token(self):
        return self.tokens[self.index]

    def _take(self, kind=None, value=None):
        token = self.token
        if kind is not None and token.kind != kind:
            return None
        if value is not None and token.value.casefold() != value.casefold():
            return None
        self.index += 1
        return token

    def _expect(self, kind, value=None):
        token = self._take(kind, value)
        if token is None:
            wanted = value if value is not None else kind
            raise Unsupported(
                "expected %s at character %d, found %r" %
                (wanted, self.token.position, self.token.value),
                "SPOTFIRE-EXPR-SYNTAX",
            )
        return token

    def _keyword(self, value):
        return self.token.kind == "IDENT" and self.token.value.casefold() == value.casefold()

    def parse(self):
        node = self._parse_or()
        if self.token.kind != "EOF":
            raise Unsupported(
                "unsupported trailing expression at character %d: %r" %
                (self.token.position, self.token.value),
                "SPOTFIRE-EXPR-TRAILING",
            )
        return node

    def _binary(self, child, operators):
        node = child()
        while True:
            token = self.token
            key = token.value.casefold()
            if token.kind not in ("OP", "IDENT") or key not in operators:
                return node
            self.index += 1
            right = child()
            target = operators[key]
            node = _Node(
                "(%s %s %s)" % (node.text, target, right.text),
                node.aggregate or right.aggregate,
                node.references | right.references,
            )

    def _parse_or(self):
        return self._binary(self._parse_and, {"or": "Or"})

    def _parse_and(self):
        return self._binary(self._parse_not, {"and": "And"})

    def _parse_not(self):
        if self._keyword("not"):
            self.index += 1
            value = self._parse_not()
            return _Node("Not(%s)" % value.text, value.aggregate, value.references)
        return self._parse_comparison()

    def _parse_comparison(self):
        node = self._parse_concat()
        operators = {"=": "=", "<>": "!=", "!=": "!=", "<": "<",
                     "<=": "<=", ">": ">", ">=": ">="}
        if self.token.kind == "OP" and self.token.value in operators:
            operator = operators[self.token.value]
            self.index += 1
            right = self._parse_concat()
            return _Node(
                "(%s %s %s)" % (node.text, operator, right.text),
                node.aggregate or right.aggregate,
                node.references | right.references,
            )
        if self._keyword("is"):
            self.index += 1
            negate = False
            if self._keyword("not"):
                self.index += 1
                negate = True
            if not self._keyword("null"):
                raise Unsupported(
                    "only IS NULL and IS NOT NULL predicates are supported",
                    "SPOTFIRE-EXPR-IS-UNSUPPORTED",
                )
            self.index += 1
            return _Node(
                ("%s(%s)" % ("IsNotNull" if negate else "IsNull", node.text)),
                node.aggregate,
                node.references,
            )
        return node

    def _parse_concat(self):
        return self._binary(self._parse_add, {"&": "&"})

    def _parse_add(self):
        return self._binary(self._parse_multiply, {"+": "+", "-": "-"})

    def _parse_multiply(self):
        return self._binary(self._parse_power, {"*": "*", "/": "/", "%": "%"})

    def _parse_power(self):
        return self._binary(self._parse_unary, {"^": "^"})

    def _parse_unary(self):
        if self.token.kind == "OP" and self.token.value in ("+", "-"):
            operator = self.token.value
            self.index += 1
            value = self._parse_unary()
            return _Node("(%s%s)" % (operator, value.text),
                         value.aggregate, value.references)
        return self._parse_primary()

    def _parse_primary(self):
        token = self.token
        if self._take("LPAREN"):
            value = self._parse_or()
            self._expect("RPAREN")
            node = _Node("(%s)" % value.text, value.aggregate, value.references)
        elif token.kind == "NUMBER":
            self.index += 1
            node = _Node(token.value)
        elif token.kind == "STRING":
            self.index += 1
            node = _Node(json.dumps(token.value, ensure_ascii=False))
        elif token.kind == "COLUMN":
            self.index += 1
            first = token.value
            if self._take("DOT"):
                second = self._expect("COLUMN").value
                node = _Node("[%s]" % second, False,
                             frozenset(("%s.%s" % (first, second),)))
            else:
                node = _Node("[%s]" % first, False, frozenset((first,)))
        elif token.kind == "IDENT":
            lowered = token.value.casefold()
            if lowered == "case":
                node = self._parse_case()
            elif lowered in ("true", "false", "null"):
                self.index += 1
                node = _Node({"true": "True", "false": "False",
                              "null": "Null"}[lowered])
            else:
                node = self._parse_function()
        else:
            raise Unsupported(
                "expected an expression at character %d, found %r" %
                (token.position, token.value),
                "SPOTFIRE-EXPR-SYNTAX",
            )

        if self._keyword("over"):
            node = self._parse_over(node)
        return node

    def _parse_function(self):
        name = self._expect("IDENT").value
        spec = _FUNCTIONS.get(name.casefold())
        if spec is None:
            raise Unsupported(
                "Spotfire function %s() is outside the verified allowlist" % name,
                "SPOTFIRE-EXPR-FUNCTION-UNSUPPORTED",
            )
        sigma_name, minimum, maximum, aggregate = spec
        self._expect("LPAREN")
        arguments = []
        if self.token.kind != "RPAREN":
            while True:
                arguments.append(self._parse_or())
                if not self._take("COMMA"):
                    break
        self._expect("RPAREN")
        count = len(arguments)
        if count < minimum or (maximum is not None and count > maximum):
            wanted = str(minimum) if minimum == maximum else (
                "%d or more" % minimum if maximum is None else
                "%d..%d" % (minimum, maximum)
            )
            raise Unsupported(
                "%s() has %d argument(s); expected %s" % (name, count, wanted),
                "SPOTFIRE-EXPR-ARITY",
            )
        return _Node(
            "%s(%s)" % (sigma_name, ", ".join(arg.text for arg in arguments)),
            aggregate or any(arg.aggregate for arg in arguments),
            frozenset().union(*(arg.references for arg in arguments)),
        )

    def _parse_case(self):
        self._expect("IDENT", "case")
        subject = None
        if not self._keyword("when"):
            subject = self._parse_or()
        branches = []
        while self._keyword("when"):
            self.index += 1
            condition = self._parse_or()
            if subject is not None:
                condition = _Node(
                    "(%s = %s)" % (subject.text, condition.text),
                    subject.aggregate or condition.aggregate,
                    subject.references | condition.references,
                )
            self._expect("IDENT", "then")
            value = self._parse_or()
            branches.append((condition, value))
        otherwise = _Node("Null")
        if self._keyword("else"):
            self.index += 1
            otherwise = self._parse_or()
        self._expect("IDENT", "end")
        if not branches:
            raise Unsupported(
                "CASE requires at least one WHEN branch",
                "SPOTFIRE-EXPR-CASE-EMPTY",
            )
        text = otherwise.text
        aggregate = otherwise.aggregate
        references = otherwise.references
        for condition, value in reversed(branches):
            text = "If(%s, %s, %s)" % (condition.text, value.text, text)
            aggregate = aggregate or condition.aggregate or value.aggregate
            references = references | condition.references | value.references
        return _Node(text, aggregate, references)

    def _parse_over(self, value):
        self._expect("IDENT", "over")
        if not value.aggregate:
            raise Unsupported(
                "OVER is accepted only on an aggregate expression",
                "SPOTFIRE-EXPR-OVER-NONAGGREGATE",
            )
        self._expect("LPAREN")
        partition = []
        if self._keyword("intersect"):
            self.index += 1
            self._expect("LPAREN")
            partition = self._parse_partition_columns()
            self._expect("RPAREN")
        elif self.token.kind == "COLUMN":
            partition = self._parse_partition_columns()
        else:
            navigator = self.token.value or self.token.kind
            raise Unsupported(
                "Spotfire OVER navigator %r is not a verified partition form; "
                "only OVER ([Column], ...) and OVER (Intersect([Column], ...)) "
                "are accepted" % navigator,
                "SPOTFIRE-EXPR-OVER-NAVIGATOR-UNSUPPORTED",
            )
        self._expect("RPAREN")
        refs = value.references | frozenset(ref for _, ref in partition)
        return _Node(
            "%s Over (%s)" % (value.text, ", ".join(text for text, _ in partition)),
            True,
            refs,
        )

    def _parse_partition_columns(self):
        columns = []
        while True:
            first = self._expect("COLUMN").value
            if self._take("DOT"):
                second = self._expect("COLUMN").value
                columns.append(("[%s]" % second, "%s.%s" % (first, second)))
            else:
                columns.append(("[%s]" % first, first))
            if not self._take("COMMA"):
                break
        return columns


def translate(expression):
    """Return a :class:`TranslationResult`; never silently passes through."""
    if not isinstance(expression, str) or not expression.strip():
        return TranslationResult(
            False,
            warning_id="SPOTFIRE-EXPR-EMPTY",
            reason="Spotfire expression is empty",
        )
    source = expression.strip()
    if source.startswith("="):
        source = source[1:].lstrip()
    try:
        node = _Parser(source).parse()
    except Unsupported as error:
        return TranslationResult(
            False,
            warning_id=error.warning_id,
            reason=str(error),
        )
    return TranslationResult(
        True,
        formula=node.text,
        kind="measure" if node.aggregate else "dimension",
        references=tuple(sorted(node.references, key=str.casefold)),
    )


def translate_expression(expression):
    """Compatibility alias for callers that prefer an explicit function name."""
    return translate(expression)


def translate_or_raise(expression):
    result = translate(expression)
    if not result.supported:
        raise Unsupported(result.reason, result.warning_id)
    return result


def classify(expression):
    """Return ``(dimension|measure, formula)`` and raise on unsupported input."""
    result = translate_or_raise(expression)
    return result.kind, result.formula


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("expression")
    arguments = parser.parse_args()
    print(json.dumps(translate(arguments.expression).as_dict(),
                     indent=2, ensure_ascii=False))
