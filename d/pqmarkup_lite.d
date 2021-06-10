/+ Translation of "pgmarkup_lite1.nim"
   Version using dchar as Runes.
+/ 
import std.utf : byDchar;
import std.array : array;
import std.range : iota, retro, repeat, drop;
import std.stdio : File;
import std.algorithm : count, countUntil, remove, canFind, min, max, startsWith;
import std.typecons : tuple;
import std.conv : to, ConvException;
import std.ascii : isDigit;
import std.string : replace;
import std.exception : enforce;

class PqmException : Exception {
    size_t line, column, pos;
    this(string message, size_t line, size_t column, size_t pos) {
        this.line = line;
        this.column = column;
        this.pos = pos;
        super(msg);
    }
}

alias Rune = dchar;
alias Runes = dchar[]; // Sequence of code points

// Procedures used to construct Rune from char and Runes from string (using 'c'.u and "s".u syntax).
Rune u(char c) { return cast(Rune)c; }
Rune u(wchar c) { return cast(Rune)c; }
Runes u(string str) { return str.byDchar.array; }
Runes u(dstring str) { return str.to!(Runes); }

immutable string[Runes] Alignments;
immutable Rune[Rune] Styles;
immutable
    LSQM = '\u2018'.u,      // Left single quotation mark (‘).
    RSQM = '\u2019'.u,      // Right single quotation mark (’).
    CyrEn = '\u041D'.u,     // Cyrillic letter EN.
    CyrO = '\u041E'.u,      // Cyrillic capital letter O.
    BOM = "\xEF\xBB\xBF";   // UTF-8 BOM.
shared static this() {
    Alignments = ["<<".u: "left", ">>".u: "right", "><".u: "center", "<>".u: "justify"];
    Styles = ['*': 'b', '_': 'u', '-': 's', '~': 'i'];
}

// Additional procedures for Runes.

size_t rfind(Runes runes, Rune c) { return rfind(runes, c, runes.length - 1); }
size_t rfind(Runes runes, Rune c, size_t start) {
    foreach (i; iota(start+1).retro) {
        if (runes[i] == c)
            return i;
    }
    return -1;
}

ptrdiff_t countUntil(R, N)(R r, N, size_t start) {
    ptrdiff_t ret = r.drop(start).countUntil(N);
    return ret == -1 ? -1 : ret + start;
}

class Converter {
    Stack!size_t toHtmlCalledInsideToHtmlOuterPosList;
    bool ohd;
    Runes runes;

    this(bool ohd) {
        this.ohd = ohd;
    }

    // Conversion to HTML.

    string toHtml(Runes runes, File outfilef = File.init, size_t outerPos = 0) {
        string res; // Result (if outfilef is nil).

        toHtmlCalledInsideToHtmlOuterPosList ~= outerPos;

        void write(const Runes s) {
            if (outfilef == File.init) res ~= s.to!(char[]);
            else outfilef.write(s);
        }

        // Save "runes" to determine the line number by character number.
        if (toHtmlCalledInsideToHtmlOuterPosList.length == 1)
            this.runes = runes;

        void exitWithError(string message, size_t pos) {
            auto
                pos2 = pos + toHtmlCalledInsideToHtmlOuterPosList.sum,
                line = 1,
                lineStart = -1,
                t = 0;
            while (t < pos2) {
                if (runes[t] == '\n') {
                    line++;
                    lineStart = t;
                }
                t++;
            }
            throw new PqmException(message, line, pos - lineStart, pos);
        }

        long i = 0; // Index in rune sequence.

        Rune nextChar(long offset = 1) {
            return i + offset < runes.length ? runes[i+offset] : '\0';
        }

        bool iNextStr(const Runes r) {
            if (i + r.length > runes.length) return false;
            foreach (size_t k, Rune rune; r) {
                if (runes[i+1+k] != rune) return false;
            }
            return true;
        }

        Rune prevChar(long offset = 1) {
            return i - offset >= 0 ? runes[i-offset] : '\0';
        }

        Runes htmlEscape(Runes r) {
            Runes result;
            foreach (rune; r) {
                if (rune == '&') result ~= "&amp;"d;
                else if (rune == '<') result ~= "&lt;"d;
                else result ~= rune;
            }
            return result;
        }

        Runes htmlEscapeQ(Runes r) {
            Runes result;
            foreach (rune; r) {
                if (rune == '&') result ~= "&amp;"d;
                else if (rune == '"') result ~= "&quot;"d;
                else result ~= rune;
            }
            return result;
        }

        long writePos = 0;

        void writeToPos(long pos, long npos) {
            if (pos > writePos)
                write(htmlEscape(runes[writePos..pos]));
            writePos = npos;
        }

        void writeToI(const Runes addStr, long skipChars = 1) {
            writeToPos(i, i + skipChars);
            write(addStr);
        }

        long findEndingPairQuote(long i) {
            assert(runes[i] == LSQM);
            auto
                startqpos = i,
                nestingLevel = 0;
            while (true) {
                if (i == runes.length)
                    exitWithError("Unpaired left single quotation mark", startqpos);
                switch (runes[i]) {
                    case LSQM:
                        nestingLevel++;
                        break;
                    case RSQM:
                        nestingLevel--;
                        if (nestingLevel == 0) return i;
                        break;
                    default:
                        break;
                }
                i++;
            }
        }

        long findEndingSqBracket(Runes r, long i, long start = 0) {
            assert(r[i] == '[');
            auto
                starti = i,
                nestingLevel = 0;
            while (true) {
                switch (r[i]) {
                    case '[':
                        nestingLevel++;
                        break;
                    case ']':
                        nestingLevel--;
                        if (nestingLevel == 0) return i;
                        break;
                    default:
                        break;
                }
                i++;
                if (i == r.length)
                    exitWithError("Unended comment started", start + starti);
            }
        }

        Runes removeComments(Runes r, long start, long level = 3) {
            if (r.length == 0) return r;
            Runes result = r;
            while (true) {
                const j = result.countUntil('['.repeat(level));
                if (j < 0) break;
                const k = findEndingSqBracket(result, j, start) + 1;
                start += k - j;
                result.remove(tuple(j, k));
            }
            return result;
        }

        Runes link;

        void writeHttpLink(long startpos, long endpos, long qOffset = 1, Runes text = []) {
            // Looking for the end of the link.
            auto nestingLevel = 0;
            i += 2;
            LOOP: while (true) {
                if (i == runes.length)
                    exitWithError("Unended link", endpos + qOffset);
                switch (runes[i]) {
                    case '[':
                        nestingLevel++;
                        break;
                    case ']':
                        if (nestingLevel == 0) break LOOP;
                        nestingLevel--;
                        break;
                    case ' ':
                        break LOOP;
                    default:
                        break;
                }
                i++;
            }

            link = htmlEscapeQ(runes[endpos+1+qOffset..i]);
            auto tag = `<a href="` ~ link ~ `"`;
            if (link.length >= 2 && link[0] == '.' && link[1] == '/')
                tag ~= ` target="_self"`d;

            // link[http://... 'title']
            if (runes[i] == ' ') {
                tag ~= ` title="`d;
                if (nextChar() == LSQM) {
                    const endqpos2 = findEndingPairQuote(i+1);
                    if (runes[endqpos2+1] != ']')
                        exitWithError("Expected `]` after `'`", endqpos2+1);
                    tag ~= htmlEscapeQ(removeComments(runes[i+2..endqpos2], i+2));
                    i = endqpos2 + 1;
                } else {
                    const endb = findEndingSqBracket(runes, endpos + qOffset);
                    tag ~= htmlEscapeQ(removeComments(runes[i+1..endb], i+1));
                    i = endb;
                }
                tag ~= `"`d;
            }
            if (nextChar() == '[' && nextChar(2) == '-') {
                auto j = i + 3;
                while (j < runes.length) {
                    if (runes[j] == ']') {
                        i = j;
                        break;
                    }
                    if (!runes[j].isDigit)
                        break;
                    j++;
                }
            }
            if (text.length == 0) {
                writeToPos(startpos, i + 1);
                text = toHtml(runes[startpos+qOffset..endpos], File.init, startpos + qOffset).u;
            }
            write(tag ~ '>' ~ (text.length ? text : link) ~ "</a>");
        }

        void writeAbbr(long startpos, long endpos, long qOffset = 1) {
            i += qOffset;
            const endqpos2 = findEndingPairQuote(i+1);
            if (runes[endqpos2+1] != ']')
                exitWithError("Bracket ] should follow after '", endqpos2 + 1);
            writeToPos(startpos, endqpos2 + 2);
            write(`<abbr title="` ~
                    htmlEscapeQ(removeComments(runes[i+2..endqpos2], i + 2)) ~ `">` ~
                    htmlEscape(removeComments(runes[startpos+qOffset..endpos], startpos + qOffset)) ~ "</abbr>");
            i += endqpos2 + 1;
        }

        Stack!dstring endingTags;
        auto newLineTag = "\0";

        while (i < runes.length) {
            const rune = runes[i];
            if (i == 0 || prevChar() == '\n' || (i == writePos && endingTags.length != 0 &&
                                                 ["</blockquote>"d, "</div>"].canFind(endingTags.last) &&
                                                 [">‘"d, "<‘", "!‘"].canFind(runes[i-2..i]))) {
                if (rune == '.' && nextChar() == ' ')
                    writeToI("•".u);
                else if (rune == ' ')
                    writeToI("&emsp;".u);
                else if ("><"d.canFind(rune) && (" ["d.canFind(nextChar()) || iNextStr("‘".u))) { // ]’
                    writeToPos(i, i + 2);
                    write(u("<blockquote" ~ (rune == '<' ? ` class="re"` : "") ~ ">"));
                    if (nextChar() == ' ') // > Quoted text.
                        newLineTag = "</blockquote>";
                    else {
                        if (nextChar() == '[') {
                            if (nextChar(2) == '-' && nextChar(3).isDigit) { // >[-1]:‘Quoted text.’ # [
                                i = runes.countUntil(']', i + 4) + 1;
                                writePos = i + 2;
                            } else {
                                // >[http...]:‘Quoted text.’ or >[http...][-1]:‘Quoted text.
                                i++;
                                const endb = findEndingSqBracket(runes, i);
                                link = runes[i+1..endb];
                                const spacepos = link.countUntil(' ');
                                if (spacepos > 0)
                                    link = link[0..spacepos];
                                else
                                    link = link[0..link.rfind('/', 46)] ~ "...";
                                writeHttpLink(i, i, 0, "<i>" ~ link ~ "</i>");
                                i++;
                                if (runes[i..i+2] != [':', LSQM])
                                    exitWithError(
                                            "Quotation with url should always have :‘...’ after [" ~
                                            link[0..link.countUntil(':')].to!string ~ "://url]", i);
                                write(":<br />\n".u);
                                writePos = i + 2;
                            }
                        } else {
                            const endqpos = findEndingPairQuote(i + 1);
                            if (endqpos < runes.length - 1) {
                                switch (runes[endqpos + 1]) {
                                    case '[': // >‘Author's name’[http...]:‘Quoted text.’ # ]
                                        const startqpos = i + 1;
                                        i = endqpos;
                                        write("<i>".u);
                                        assert(writePos == startqpos + 1);
                                        writePos = startqpos;
                                        writeHttpLink(startqpos, endqpos);
                                        write("</i>".u);
                                        i++;
                                        if (i == runes.length - 1 || runes[i..i+2] != [':', LSQM])
                                            exitWithError("Quotation with url should always have :‘...’ after [" ~
                                                    link[0..link.countUntil(':')].to!string ~ "://url]", i);
                                        write(":<br />\n".u);
                                        writePos = i + 2;
                                        break;
                                    case ':':
                                        write("<i>" ~ runes[i+2..endqpos] ~ "</i>:<br />\n");
                                        i = endqpos + 1;
                                        if (i == runes.length - 1 || runes[i..i+2] != [':', LSQM])
                                            exitWithError(
                                                    "Quotation with author's name should be in the form >‘Author's name’:‘Quoted text.’", i);
                                        writePos = i + 2;
                                        break;
                                    default:
                                        break;
                                }
                            }
                        }
                        endingTags ~= "</blockquote>";
                    }
                    i += 2;
                    continue;
                }
            }

            switch (rune) {

                case LSQM: // ‘
                    auto prevci = i - 1;
                    auto prevc = prevci >= 0 ? runes[prevci] : '\0';
                    const startqpos = i;
                    i = findEndingPairQuote(i);
                    const endqpos = i;
                    auto strInP = "".u;
                    if (prevc == ')') {
                        const openp = runes.rfind('(', prevci - 1);
                        if (openp > 0) {
                            strInP = runes[openp+1..startqpos-1];
                            prevci = openp - 1;
                            prevc = runes[prevci];
                        }
                    }
                    if (iNextStr("[http"d) || iNextStr("[./"d))
                        writeHttpLink(startqpos, endqpos);
                    else if (iNextStr("[‘"))
                        writeAbbr(startqpos, endqpos);
                    else if (['0', 'O', CyrO].canFind(prevc)) {
                        writeToPos(prevci, endqpos + 1);
                        write(htmlEscape(runes[startqpos+1..endqpos]).replace("\n", "<br />\n"));
                    } else if ("<>".canFind(prevc) && "<>".canFind(runes[prevci-1])) { // text alignment
                        writeToPos(prevci - 1, endqpos + 1);
                        write(u(`<div align="` ~ Alignments[[runes[prevci-1], prevc]] ~ `">` ~
                                    toHtml(runes[startqpos+1..endqpos], File.init, startqpos + 1) ~ "</div>\n"));
                        newLineTag = "";
                    } else if (iNextStr(":‘") && runes[findEndingPairQuote(i+2)+1] == '<') {
                        // reversed quote ‘Quoted text.’:‘Author's name’< # ’
                        const endrq = findEndingPairQuote(i + 2);
                        i = endrq + 1;
                        writeToPos(prevci + 1, i + 1);
                        write("<blockquote>"d ~ toHtml(runes[startqpos+1..endqpos], File.init, startqpos+1).u ~
                                "<br />\n<div align='right'><i>"d ~ runes[endqpos+3..endrq] ~ "</i></div></blockquote>"d);
                        newLineTag = "";
                    }
                    else {
                        i = startqpos; // roll back the position.
                        if ("*_-~"d.canFind(prevc)) {
                            writeToPos(i - 1, i + 1);
                            const tag = Styles[prevc];
                            write(['<', tag, '>']);
                            endingTags ~= ['<', '/', tag, '>'];
                        } else if (['H', CyrEn].canFind(prevc)) {
                            writeToPos(prevci, i + 1);
                            long val = 0;
                            if (strInP.length > 0) {
                                try {
                                    val = strInP.to!long;
                                } catch (ConvException e) {
                                    exitWithError("wrong integer value: " ~ strInP.to!string, i);
                                }
                            }
                            const tag = "h" ~ min(max(3 - val, 1), 6).to!dstring;
                            write("<"d ~ tag ~ ">"d);
                            endingTags ~= "</"d ~ tag ~ ">"d;
                        } else if (prevci > 0 && ["/\\"d, "\\/"d].canFind([runes[prevci-1], prevc])) {
                            writeToPos(prevci-1, i + 1);
                            const tag = [runes[prevci-1], prevc] == "/\\" ? "sup"d : "sub"d;
                            write("<"d ~ tag ~ ">"d);
                            endingTags ~= "</"d ~ tag ~ ">"d;
                        } else if (prevc == '!') {
                            writeToPos(prevci, i + 1);
                            write(`<div class="note">`);
                            endingTags ~= "</div>";
                        } else { // ‘
                            endingTags ~= "’";
                        }
                    }
                    break;

                case RSQM:
                    writeToPos(i, i + 1);
                    if (endingTags.length == 0)
                        exitWithError("Unpaired right single quotation mark", i);
                    const last = endingTags.pop;
                    write(last);
                    if (nextChar() == '\n' && (last.startsWith("</h") || ["</blockquote>"d, "</div>"d].canFind(last))) {
                        // since <h.> is a block element, it automatically terminates the line, so you don't need to
                        // add an extra <br> tag in this case (otherwise you will get an extra empty line after the header)
                        write("\n"d);
                        i++;
                        writePos++;
                    }
                    break;

                case '`':
                    // First, count the number of characters `;
                    // this will determine the boundary where the span of code ends.
                    const start = i;
                    i++;
                    while (i < runes.length) {
                        if (runes[i] != '`') break;
                        i++;
                    }
                    const endpos = runes[i..$].countUntil('`'.repeat(i - start), i);
                    if (endpos < 0)
                        exitWithError("Unended ` started", start);
                    writeToPos(start, endpos + i - start);
                    auto r = runes[i..endpos];
                    const delta = r.count(LSQM) - r.count(RSQM); // `backticks` and [[[comments]]] can contain ‘quotes’ (for example: [[[‘]]]`Don’t`), that's why.
                    if (delta > 0) { // this code is needed [:backticks]
                        foreach (ii; 0 .. delta) // ‘‘
                            endingTags ~= "’";
                    } else {
                        foreach (ii; iota(delta+1).retro)
                            if (endingTags.pop != "’")
                                exitWithError("Unpaired single quotation mark found inside code block/span beginning", start);
                    }
                    r = htmlEscape(r);
                    if (!r.canFind('\n')) // this is a single-line code -‘block’span
                        write(`<pre class="inline_code">`d ~ r ~ "</pre>"d);
                    else {
                        write("<pre>"d ~ r ~ "<pre>\n"d);
                        newLineTag = "";
                    }
                    i += endpos - start - 1;
                    break;

                case '[':
                    if (iNextStr("http") || iNextStr("../") ||
                            iNextStr("‘") && !"\r\n\t \0".canFind(prevChar())) { // ’
                        auto s = i - 1;
                        while (s >= writePos && !"\r\n\t [{(".canFind(runes[s]))
                            s--;
                        if (iNextStr("‘")) // ’
                            writeAbbr(s + 1, i, 0);
                        else if (iNextStr("http") || iNextStr("./"))
                            writeHttpLink(s + 1, i, 0);
                        else
                            assert(0);
                    } else if (iNextStr("[[")) {
                        const commentStart = i;
                        auto nestingLevel = 0;
                        LOOP: while (true) {
                            switch (runes[i]) {
                                case '[':
                                    nestingLevel++;
                                    break;
                                case ']':
                                    nestingLevel--;
                                    if (nestingLevel == 0) break LOOP;
                                    break;
                                case LSQM: // [backticks:] and this code
                                    endingTags ~= "’"; // ‘‘
                                    break;
                                case RSQM:
                                    enforce(endingTags.pop == "’", "assertion failed");
                                    break;
                                default:
                                    break;
                            }
                            i++;
                            if (i == runes.length)
                                exitWithError("Unended comment started", commentStart);
                        } 
                        writeToPos(commentStart, i + 1);
                    } else {
                        if (ohd)
                            writeToI(`"<span class="sq"><span class="sq_brackets">[</span>`.u);
                        else
                            writeToI("[".u);
                    }
                    break;

                case ']': // [
                    if (ohd)
                        writeToI(`<span class="sq_brackets">]</span></span>`d);
                    else
                        writeToI("]");
                    break;

                case '{':
                    if (ohd)
                        writeToI(`<span class="cu_brackets" onclick="return spoiler(this, event)"><span class="cu_brackets_b">{</span><span>…</span><span class="cu" style="display: none">`d);
                    else
                        writeToI("{");
                    break;

                case '}':
                    if (ohd)
                        writeToI(`</span><span class="cu_brackets_b">}</span></span>`);
                    else
                        writeToI("}");
                    break;

                case '\n':
                    writeToI((newLineTag != "\0" ? newLineTag.u : "<br />"d) ~ (newLineTag != "" ? "\n"d : ""d));
                    newLineTag = "\0";
                    break;

                default:
                    break;
            }
            i++;
        }

        writeToPos(runes.length, 0);
        if (endingTags.length != 0) // there is an unclosed opening/left quote somewhere.
            exitWithError("Unclosed left single quotation mark somewhere", runes.length);

        enforce(toHtmlCalledInsideToHtmlOuterPosList.pop() == outerPos, "assertion failure");

        if (outfilef == File.init)
            return res;
        return res;
    }
}

string toHtml(string instr, File outfilef, bool ohd = false) {
    auto conv = new Converter(ohd);
    return conv.toHtml(instr.to!(Runes), outfilef);
}

string toHtml(string instr, bool ohd = false) {
    auto conv = new Converter(ohd);
    return conv.toHtml(instr.to!(Runes));
}

// Nim seq[T] are value types, but a D dynamic array--if used as endingTags is
// used in this code--would fall for one of the classic blunders.
struct Stack(T) {
    private T[] a;
    @property size_t length() { return a.length; }
    T last() { return a[$-1]; }
    void opOpAssign(string op)(T x) if (op == "~") { a ~= x; }
    T pop() {
        T ret = a[$-1];
        a.length--;
        a.assumeSafeAppend;
        return ret;
    }
    @disable this(this);

    import std.traits : isNumeric;
    static if (isNumeric!T) { // for toHtmlCalled...List
        T sum() { import std.algorithm : sum; return a.sum; }
    }
}
