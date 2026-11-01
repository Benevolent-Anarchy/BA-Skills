import importlib.util
import sys
from pathlib import Path
import unittest
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('gate_markdown',ROOT/'skills/ba-bootstrap/assets/project/tools/verify_linux.py'); g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
class Markdown(unittest.TestCase):
    def test_code_in_heading_and_wiki_destination_is_preserved(self):
        result=g.tokens('# Topic\n## Behaviour of `Size`\n`[[missing#Target]]`\n<!-- [[also-missing]] -->\n[[design/topic#Behaviour of `Size`|Size]]\n')
        self.assertEqual(result['headings'][1][1],'Behaviour of `Size`'); self.assertEqual(result['headings'][1][3],'behaviour-of-size'); self.assertEqual([x['target'] for x in result['links']],['design/topic#Behaviour of `Size`'])
    def test_fence_close_must_be_plain_and_long_enough(self):
        result=g.tokens('````markdown\n## Hidden\n```\n[[hidden]]\n```` trailing text\n## Still hidden\n````\n## Visible\n    ## Indented example\n    [[also-hidden]]\n~~~\n## Tilde hidden\n```\n~~~\n## After tilde\n')
        self.assertEqual([x[1] for x in result['headings']],['Visible','After tilde']); self.assertEqual(result['links'],[])
    def test_comment_markers_inside_real_multiline_code_are_literal(self):
        result=g.tokens('# Topic\n<!-- comment ` --> ## After HTML\n%% comment ` %% ## After Obsidian\n<!--\n## Hidden HTML\n` -->\n## Live\n%%\n## Hidden Obsidian\n` %%\n## Also live\nText `literal <!-- across\nlines` [[design/live|Live]].\n')
        titles=[x[1] for x in result['headings']]
        self.assertIn('Live',titles); self.assertIn('Also live',titles); self.assertNotIn('Hidden HTML',titles); self.assertNotIn('Hidden Obsidian',titles)
        self.assertEqual([x['target'] for x in result['links']],['design/live'])
    def test_unmatched_code_spans_cannot_cross_markdown_blocks(self):
        result=g.tokens('## Heading with stray `\n<!-- comment `\n## Hidden\n-->\n## Live\nAn unmatched ` stays literal.\n\n[[design/live]]\n``[[hidden]]``\n')
        self.assertEqual([x[1] for x in result['headings']],['Heading with stray `','Live']); self.assertEqual(len(result['links']),1)
    def test_references_angle_paths_balanced_paths_images_and_escapes(self):
        result=g.tokens('# Topic\n[ordinary](<some file.md#some-heading>)\n[reference][record]\n![image](images/picture.png)\n[[#Heading|Alias]]\n\\[[escaped]]\n\n[record]: decisions/input.md#keyboard-navigation\n[external](https://example.invalid/no-network)\n[balanced](notes/a(b).md)\n')
        self.assertEqual(len(result['links']),6,result['links']); self.assertIn('notes/a(b).md',[x['target'] for x in result['links']])
    def test_invalid_backtick_info_and_even_backslashes(self):
        result=g.tokens('```not `valid fence info\n## Behaviour of `Size`\n## Behaviour of `Colour`\n~~~\n## Hidden\n    ~~~\n## Still hidden\n~~~\n## Visible\n\\\\[[live]]\n')
        self.assertEqual([x[1] for x in result['headings']],['Behaviour of `Size`','Behaviour of `Colour`','Visible']); self.assertEqual([x['target'] for x in result['links']],['live'])
class HtmlAndLabels(unittest.TestCase):
    def test_inline_spans_keep_exact_offsets_through_block_normalization(self):
        cases=(
            '\u00a0\u00a0\u00a0\nWrite `%%` and [[live]].\n',
            '- \u00a0\n  Write `%%` and [[live]].\n',
            '> \u00a0\n> Write `%%` and [[live]].\n',
            '- item\n\tmore `x`[[live]] end\n',
            '> - item\n>\tmore `x`[[live]] end\n',
            '\u3000\nWrite `%%` and [[live]].\n---\n',
            '# \u3000 Write `%%` and [[live]]. ###\n',
            '> \u00a0\n> text <!-- [[hidden]] --> [[live]]\n',
        )
        for text in cases:
            with self.subTest(text=text):
                spans=g.inline_spans(text,g.MARKDOWN.parse(text,{}))
                expected='<!-- [[hidden]] -->' if '<!--' in text else '`%%`' if '`%%`' in text else '`x`'
                self.assertEqual(spans,[(text.index(expected),text.index(expected)+len(expected))])
                self.assertEqual([link['target'] for link in g.tokens(text)['links']],['live'])

    def test_real_html_comments_hide_wiki_links_in_containers_and_image_alts(self):
        for text in ('> text <!-- note\n> [[hidden]]\n> --> end\n','- text <!-- note\n  [[hidden]]\n  --> end\n','![alt <!-- [[hidden]] --> end](present.md)\n'):
            with self.subTest(text=text):
                result=g.tokens(text)
                self.assertEqual([link for link in result['links'] if link['kind']=='wiki'],[])

    def test_unicode_separators_do_not_split_inline_code(self):
        for separator in ('\u2028','\u2029','\x85','\v','\f','\x1c','\x1d','\x1e','\u00a0','\u2003'):
            with self.subTest(separator=repr(separator)):
                for text in ('`code'+separator+'## [[hidden]]` [[live]]\n','`code\n'+separator+'\nlast [[hidden]]` [[live]]\n','`code\n##'+separator+'[[hidden]]` [[live]]\n'):
                    result=g.tokens(text)
                    self.assertEqual([link['target'] for link in result['links']],['live'])

    def test_wiki_links_do_not_inherit_commonmark_reference_targets(self):
        result=g.tokens('[[design/live]]\n\n[design/live]: missing.md\n')
        self.assertEqual([(link['kind'],link['target']) for link in result['links']],[('wiki','design/live')])

    def test_html_block_contents_and_attributes_do_not_become_markdown(self):
        result=g.tokens('<div title="[[hidden]]">\n## Hidden HTML\n[[also-hidden]]\n</div>\n\n## Visible\n')
        self.assertEqual([h[1] for h in result['headings']],['Visible']); self.assertEqual(result['links'],[])
    def test_formatted_markdown_link_labels_are_plain_text(self):
        result=g.tokens('[**Overview**](topic.md#overview) [Code `Size`](topic.md#code-size)\n')
        self.assertEqual([x['label'] for x in result['links']],['Overview','Code Size'])

class ContainerBlocks(unittest.TestCase):
    def test_live_list_link_matrix_preserves_nested_containers_and_references(self):
        cases={
            'nested bullet':'- Resources\n    - [Missing](missing.md)\n',
            'ordered and continuation':'1. Resources\n   - Nested\n       [Missing](missing.md)\n',
            'nested reference':'- Resources\n    - [Missing][target]\n\n[target]: missing.md\n',
            'list reference definition':'- Resources\n    - [Missing][target]\n\n      [target]: missing.md\n',
            'wiki nested list':'- Resources\n    - [[missing]]\n',
            'tab nested list':'- Resources\n\t- [Missing](missing.md)\n',
            'deep nested bullet':'- First\n  - Second\n    - Third\n      - [Missing](missing.md)\n',
        }
        for label,text in cases.items():
            with self.subTest(label=label): self.assertEqual([x['target'] for x in g.tokens(text)['links']],['missing' if 'wiki' in label else 'missing.md'])
    def test_actual_code_inside_and_outside_lists_is_masked(self):
        cases={
            'root indented':'    [Ignored](missing.md)\n',
            'root tab':'\t[Ignored](missing.md)\n',
            'list indented':'- Resources\n\n      [Ignored](missing.md)\n',
            'nested indented':'- Resources\n    - Nested\n\n          [Ignored](missing.md)\n',
            'list fence':'- Resources\n\n    ```markdown\n    [Ignored](missing.md)\n    ```\n',
            'nested list fence':'- Resources\n    - Nested\n\n      ~~~markdown\n      [Ignored](missing.md)\n      ~~~\n',
            'inline code':'- Resources\n    - `[Ignored](missing.md)`\n',
            'indented reference':'- Resources\n\n      [target]: missing.md\n\n[Not a reference][target]\n',
        }
        for label,text in cases.items():
            with self.subTest(label=label): self.assertEqual(g.tokens(text)['links'],[])
    def test_nested_fence_ends_with_its_container_then_sibling_links_are_live(self):
        text='- Resources\n    - Nested\n\n      ```markdown\n      [Ignored](hidden.md)\n\n- [Missing](missing.md)\n'
        self.assertEqual([x['target'] for x in g.tokens(text)['links']],['missing.md'])

if __name__=='__main__': unittest.main()
