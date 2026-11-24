module matn.editor.indentguides;

import std.algorithm : min, max, clamp;
import matn.platform.sdl;
import matn.platform.font;
import matn.ui.grid.cell : Color;
import matn.ui.grid.renderer : drawRealLine;
import matn.extension.base;

/// A vertical scope/indent guide line connecting an opening bracket to its close
struct BlockGuide
{
    int openLine;
    int closeLine;
    int visualCol;
    Color color;
}

/// Indent Guides Extension (Rainbow Bracket & Block Scope Hierarchy)
class IndentGuidesExtension : Extension
{
    private Color _guideColor = Color(65, 75, 105, 255);
    private BlockGuide[] _guides;

    this()
    {
        super(ExtensionManifest(
            "matn.indentguides",
            "Indent Guides",
            "1.1.0",
            "Matn Core",
            "Vertical block hierarchy and rainbow bracket scope connector lines",
            true
        ));
        this._enabled = true;
    }

    override protected void onActivate()
    {
        if (_context)
        {
            _context.registerSetting("EDITOR", "Indent Guides", "Vertical indent lines showing block hierarchy", {
                _enabled = !_enabled;
            });
        }
    }

    @property Color guideColor() const { return _guideColor; }
    @property const(BlockGuide)[] guides() const { return _guides; }

    /// Compute leading visual indentation column accounting for tabs
    static int getVisualCol(const(dchar[]) text, int tabWidth) pure nothrow @safe
    {
        int col = 0;
        foreach (c; text)
        {
            if (c == ' ') col++;
            else if (c == '\t') col = (col / tabWidth + 1) * tabWidth;
            else break;
        }
        return col;
    }

    /// Recompute block hierarchy guides from buffer lines, matching the Matn GUI rainbow-brackets logic
    void updateGuides(const(dchar[][]) lines, int tabWidth, const(Color)[] rainbowColors = null)
    {
        _guides = [];
        if (!_enabled || lines.length == 0 || tabWidth <= 0) return;

        struct OpenBracket
        {
            int line;
            dchar bracket;
            Color color;
        }

        OpenBracket[] stack;
        int depth = 0;

        enum State
        {
            code,
            lineComment,
            blockComment,
            dquote,
            squote,
            backtick
        }

        State state = State.code;
        bool inEscape = false;
        dchar prev = 0;

        foreach (r, ref line; lines)
        {
            // Line comments and single-quote char literals do not cross line boundaries
            if (state == State.lineComment || state == State.squote)
            {
                state = State.code;
                inEscape = false;
            }

            foreach (c; line)
            {
                final switch (state)
                {
                case State.code:
                    if (prev == '/' && c == '/')
                    {
                        state = State.lineComment;
                    }
                    else if (prev == '/' && c == '*')
                    {
                        state = State.blockComment;
                    }
                    else if (c == '#')
                    {
                        state = State.lineComment;
                    }
                    else if (c == '"')
                    {
                        state = State.dquote;
                        inEscape = false;
                    }
                    else if (c == '\'')
                    {
                        state = State.squote;
                        inEscape = false;
                    }
                    else if (c == '`')
                    {
                        state = State.backtick;
                    }
                    else if (c == '(' || c == '[' || c == '{')
                    {
                        Color cColor = (rainbowColors.length > 0)
                            ? rainbowColors[depth % rainbowColors.length]
                            : _guideColor;
                        stack ~= OpenBracket(cast(int) r, c, cColor);
                        depth++;
                    }
                    else if (c == ')' || c == ']' || c == '}')
                    {
                        dchar wantOpen = (c == ')') ? '(' : ((c == ']') ? '[' : '{');
                        int matchIdx = -1;
                        foreach_reverse (si, ref ob; stack)
                        {
                            if (ob.bracket == wantOpen)
                            {
                                matchIdx = cast(int) si;
                                break;
                            }
                        }
                        if (matchIdx >= 0)
                        {
                            auto open = stack[matchIdx];
                            stack = stack[0 .. matchIdx];
                            if (depth > 0)
                                depth--;

                            // Only curly braces and square brackets generate block hierarchy guides
                            // Parentheses '(...)' are expressions/parameter lists and do not generate vertical lines
                            if ((open.bracket == '{' || open.bracket == '[') && cast(int) r > open.line + 1)
                            {
                                int openCol = getVisualCol(lines[open.line], tabWidth);
                                int closeCol = getVisualCol(lines[r], tabWidth);
                                int visualCol = min(openCol, closeCol);

                                _guides ~= BlockGuide(open.line, cast(int) r, visualCol, open.color);
                            }
                        }
                    }
                    break;
                case State.lineComment:
                    break;
                case State.blockComment:
                    if (prev == '*' && c == '/')
                        state = State.code;
                    break;
                case State.dquote:
                    if (inEscape)
                        inEscape = false;
                    else if (c == '\\')
                        inEscape = true;
                    else if (c == '"')
                        state = State.code;
                    break;
                case State.squote:
                    if (inEscape)
                        inEscape = false;
                    else if (c == '\\')
                        inEscape = true;
                    else if (c == '\'')
                        state = State.code;
                    break;
                case State.backtick:
                    if (c == '`')
                        state = State.code;
                    break;
                }
                prev = c;
            }
            prev = '\n';
            inEscape = false;
        }
    }

    /// Represents a vertical line segment for rendering
    static struct GuideSegment
    {
        float top;
        float bottom;
    }

    /// Computes the vertical Y segments for a guide, splitting around any inline change/review row
    static size_t computeGuideSegments(int guideStartLine, int guideEndLine,
                                       int scrollRow, int startRow, float padY, float lineHeight,
                                       int changeScreenRow, int changeRowCount, int changeDocLine,
                                       ref GuideSegment[2] outSegments)
    {
        bool hasChange = (changeScreenRow >= 0 && changeRowCount > 0 && changeDocLine >= 0);
        float changeY1 = 0;
        float changeY2 = 0;
        if (hasChange)
        {
            changeY1 = padY + changeScreenRow * lineHeight;
            changeY2 = padY + (changeScreenRow + changeRowCount) * lineHeight;
        }

        auto lineToY = (int line) {
            int screenLine = line - scrollRow;
            if (hasChange && line >= changeDocLine)
                screenLine += changeRowCount;
            return padY + (startRow + screenLine) * lineHeight;
        };

        float gy1 = lineToY(guideStartLine);
        float gy2 = lineToY(guideEndLine);

        if (hasChange && guideStartLine < changeDocLine && guideEndLine >= changeDocLine)
        {
            outSegments[0] = GuideSegment(gy1, max(gy1, changeY1 - 1));
            outSegments[1] = GuideSegment(changeY2, gy2);
            return 2;
        }
        else
        {
            outSegments[0] = GuideSegment(gy1, gy2);
            return 1;
        }
    }

    /// Render clean vector hairlines in Pass 3 (same as Matn GUI version)
    void renderReal(SDL_Renderer* renderer, FontEngine font,
                    int cursorRow, int scrollRow, int scrollCol,
                    int startRow, int editRows, int startCol, int editCols,
                    float padX, float padY, Color activeColor,
                    int changeScreenRow = -1, int changeRowCount = 0, int changeDocLine = -1)
    {
        if (!_enabled || _guides.length == 0) return;

        // Find the active guide whose span most tightly encloses cursorRow
        int activeGuideIdx = -1;
        int activeSpan = int.max;
        foreach (i, ref g; _guides)
        {
            if (g.openLine <= cursorRow && cursorRow <= g.closeLine)
            {
                int span = g.closeLine - g.openLine;
                if (span < activeSpan)
                {
                    activeSpan = span;
                    activeGuideIdx = cast(int) i;
                }
            }
        }

        float minTop = padY + startRow * font.lineHeight;
        float maxBottom = padY + (startRow + editRows) * font.lineHeight;

        foreach (i, ref g; _guides)
        {
            // Horizontal bounds check
            if (g.visualCol < scrollCol || g.visualCol >= scrollCol + editCols)
                continue;

            // Vertical bounds check: connector runs from line (openLine + 1) down to (closeLine)
            int guideStartLine = g.openLine + 1;
            int guideEndLine = g.closeLine;
            if (guideEndLine < scrollRow || guideStartLine >= scrollRow + editRows)
                continue;

            float gx = padX + (startCol + (g.visualCol - scrollCol)) * font.charWidth;

            GuideSegment[2] segments;
            size_t segCount = computeGuideSegments(guideStartLine, guideEndLine,
                                                   scrollRow, startRow, padY, font.lineHeight,
                                                   changeScreenRow, changeRowCount, changeDocLine,
                                                   segments);

            bool isActive = (cast(int) i == activeGuideIdx);

            foreach (ref s; segments[0 .. segCount])
            {
                float sy1 = clamp(s.top, minTop, maxBottom);
                float sy2 = clamp(s.bottom, minTop, maxBottom);

                if (sy2 <= sy1) continue;

                if (isActive)
                {
                    // Active scope: prominent thick bar with full accent/rainbow color (3px centered on gx)
                    Color c = (g.color.a > 0) ? g.color : activeColor;
                    SDL_SetRenderDrawColor(renderer, c.r, c.g, c.b, c.a);
                    SDL_FRect r = SDL_FRect(gx - 1, sy1, 3, sy2 - sy1);
                    SDL_RenderFillRect(renderer, &r);
                }
                else
                {
                    // Inactive scope: subtle dimmed 1px hairline
                    Color c = Color(
                        cast(ubyte)(g.color.r * 0.45f),
                        cast(ubyte)(g.color.g * 0.45f),
                        cast(ubyte)(g.color.b * 0.45f),
                        180
                    );
                    drawRealLine(renderer, gx, sy1, gx, sy2, c);
                }
            }
        }
    }
}

unittest
{
    auto ext = new IndentGuidesExtension();

    // 1. Block hierarchy guide extraction
    dchar[][] code = [
        "void test() {"d.dup,
        "    if (true) {"d.dup,
        "        int x = 1;"d.dup,
        "    }"d.dup,
        "}"d.dup
    ];

    ext.updateGuides(code, 4);
    auto guides = ext.guides;
    assert(guides.length == 2, "Should detect 2 block guides");
    assert(guides[0].openLine == 1 && guides[0].closeLine == 3);
    assert(guides[1].openLine == 0 && guides[1].closeLine == 4);

    // 2. Guide segment splitting around change row
    IndentGuidesExtension.GuideSegment[2] segs;

    // Normal rendering without change row
    size_t count = IndentGuidesExtension.computeGuideSegments(
        1, 10, 0, 0, 0.0f, 20.0f, -1, 0, -1, segs
    );
    assert(count == 1);
    assert(segs[0].top == 20.0f);
    assert(segs[0].bottom == 200.0f);

    // Guide with top bar offset (startRow = 3) shifts Y positions down by startRow * lineHeight
    count = IndentGuidesExtension.computeGuideSegments(
        1, 10, 0, 3, 0.0f, 20.0f, -1, 0, -1, segs
    );
    assert(count == 1);
    assert(segs[0].top == (3 + 1) * 20.0f, "Guide top must include top offset startRow");
    assert(segs[0].bottom == (3 + 10) * 20.0f, "Guide bottom must include top offset startRow");

    // Guide spanning across change row at line 5 (change row at screen row 5 with 2 rows height)
    // changeY1 = 5 * 20 = 100.0f, changeY2 = (5 + 2) * 20 = 140.0f
    count = IndentGuidesExtension.computeGuideSegments(
        1, 10, 0, 0, 0.0f, 20.0f, 5, 2, 5, segs
    );
    assert(count == 2, "Should split into 2 segments around the change row");
    assert(segs[0].top == 20.0f);
    assert(segs[0].bottom <= 99.0f, "First segment must stop before change row top");
    assert(segs[1].top == 140.0f, "Second segment must start at change row bottom");
    assert(segs[1].bottom == 240.0f, "Second segment bottom shifted down by 2 rows (10 + 2 = 12 * 20)");

    // Guide entirely above change row (lines 1..4, change at line 5)
    count = IndentGuidesExtension.computeGuideSegments(
        1, 4, 0, 0, 0.0f, 20.0f, 5, 2, 5, segs
    );
    assert(count == 1);
    assert(segs[0].top == 20.0f);
    assert(segs[0].bottom == 80.0f);

    // Guide entirely below change row (lines 6..10, change at line 5)
    count = IndentGuidesExtension.computeGuideSegments(
        6, 10, 0, 0, 0.0f, 20.0f, 5, 2, 5, segs
    );
    assert(count == 1);
    assert(segs[0].top == 160.0f, "Shifted by 2 rows (6 + 2 = 8 * 20)");
    assert(segs[0].bottom == 240.0f, "Shifted by 2 rows (10 + 2 = 12 * 20)");

    // 3. Unaligned long defined method with multiline parameters
    dchar[][] longMethodCode = [
        "    void computeGuideSegments(int guideStartLine, int guideEndLine,"d.dup,
        "                              int scrollRow, int startRow,"d.dup,
        "                              ref GuideSegment[2] outSegments) {"d.dup,
        "        bool hasChange = true;"d.dup,
        "    }"d.dup
    ];
    ext.updateGuides(longMethodCode, 4);
    assert(ext.guides.length == 1, "Should detect exactly 1 block guide for long method");
    assert(ext.guides[0].visualCol == 4, "Guide line must align with method indentation (col 4), not the param line (col 30)");
    assert(ext.guides[0].openLine == 2 && ext.guides[0].closeLine == 4);

    // 4. Char literals and escaped characters should not trigger fake block guides
    dchar[][] charCode = [
        "void test() {"d.dup,
        "    char a = '\'';"d.dup,
        "    char b = '\\\\';"d.dup,
        "    auto brace = h.indexOf('{');"d.dup,
        "    if (true) {"d.dup,
        "        int x = 1;"d.dup,
        "    }"d.dup,
        "}"d.dup
    ];
    ext.updateGuides(charCode, 4);
    assert(ext.guides.length == 2, "Char literals must not create block guides (only test and if)");
    assert(ext.guides[0].openLine == 4 && ext.guides[0].closeLine == 6);
    assert(ext.guides[1].openLine == 0 && ext.guides[1].closeLine == 7);
}
