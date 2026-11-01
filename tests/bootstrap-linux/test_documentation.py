import importlib.util
import sys
from pathlib import Path
import tempfile
import unittest
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('gate_docs',ROOT/'skills/ba-bootstrap/assets/project/tools/verify_linux.py'); g=importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
class Documentation(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='canon ü spaces '); self.addCleanup(self.tmp.cleanup); self.root=Path(self.tmp.name)
        def write(path,text):
            p=self.root/path; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(text)
        self.write=write
        for corpus in ('design','decisions','judgements'):
            heading='## Overview' if corpus=='design' else '## 2026-10-09\n\n### Keyboard navigation' if corpus=='decisions' else '### Focus is visible\n*Judged 2024-02-29, on Windows desktop.*'
            write('docs/'+corpus+'/interface.md','# Interface\n\n'+heading+'\nBody.\n')
            record='Overview' if corpus=='design' else 'Keyboard navigation' if corpus=='decisions' else 'Focus is visible'
            suffix=' — Judged 2024-02-29, on Windows desktop' if corpus=='judgements' else ''
            write('docs/'+corpus.upper()+'.md','# '+corpus+'\n\n## Index\n### Interface — [['+corpus+'/interface|Interface]]\n- [['+corpus+'/interface#'+record+'|'+record+']]'+suffix+'\n')
    def test_populated_canon_passes_and_requires_all_topic_entries(self):
        self.assertTrue(g.documentation(self.root)['Passed'],g.documentation(self.root))
        p=self.root/'docs/DESIGN.md'; p.write_text(p.read_text().replace('- [[design/interface#Overview|Overview]]',''))
        result=g.documentation(self.root); self.assertFalse(result['Passed']); self.assertTrue(any('not-indexed' in x for x in result['Diagnostics']))
    def test_unicode_dotted_names_encoded_paths_and_comments(self):
        self.write('docs/Version 1.0.md','# Café\n\n## Ångström test\n[Self](#ångström-test) [[#Ångström test|Self]]\n')
        self.write('docs/NEXT.md','[[Version 1.0]] [[Version 1.0#Ångström test|Alias]] [Alias](Version%201.0.md#%C3%A5ngstr%C3%B6m-test)\n<!-- [ignored](missing.md) -->')
        self.assertTrue(g.documentation(self.root)['Passed'],g.documentation(self.root))
    def test_missing_duplicate_group_and_exact_title_are_errors(self):
        p=self.root/'docs/DESIGN.md'; original=p.read_text()
        for text,code in [(original+'- [[design/interface#Overview|Overview]]\n','duplicate-index'),(original.replace('design/interface|Interface','design/interface|Wrong'),'topic-title'),(original.replace('### Interface — [[design/interface|Interface]]','### Interface'),'index-group')]:
            p.write_text(text); result=g.documentation(self.root); self.assertFalse(result['Passed']); self.assertTrue(any(code in x for x in result['Diagnostics']),result)
    def test_invalid_decision_date_is_rejected(self):
        p=self.root/'docs/decisions/interface.md'; p.write_text(p.read_text().replace('2026-10-09','2026-02-30'))
        self.assertTrue(any('decision-date' in x for x in g.documentation(self.root)['Diagnostics']))
    def test_judgements_require_independent_immediate_fields_and_copied_index(self):
        p=self.root/'docs/judgements/interface.md'; original=p.read_text()
        for statement in ['Judged 2026-02-30, on Windows desktop.','Judged 2026-10-09, on 2026-10-09.','Judged 2026-10-09. Prose on Windows desktop.','Judged x2026-10-09y, on Windows desktop.','Judged 2026-10-09, on 1234.']:
            p.write_text(original.replace('Judged 2024-02-29, on Windows desktop.',statement)); result=g.documentation(self.root)
            self.assertTrue(any('judgement-fields' in x for x in result['Diagnostics']),result)
        p.write_text(original.replace('*Judged','\n*Judged')); self.assertTrue(any('judgement-metadata' in x for x in g.documentation(self.root)['Diagnostics']))
        p.write_text(original); index=self.root/'docs/JUDGEMENTS.md'; index.write_text(index.read_text().replace('Windows desktop','Wrong computer')); self.assertTrue(any('judgement-index' in x for x in g.documentation(self.root)['Diagnostics']))
    def test_incomplete_historical_record_warns_and_is_not_trusted_acceptance(self):
        for path in ['docs/judgements/interface.md','docs/JUDGEMENTS.md']:
            p=self.root/path; p.write_text(p.read_text().replace('Judged 2024-02-29, on Windows desktop','Judged Date not recorded, Hardware not recorded. Incomplete historical record'))
        result=g.documentation(self.root); self.assertTrue(result['Passed'],result); self.assertTrue(any('warning: incomplete-record' in x for x in result['Diagnostics']))
    def test_case_paths_links_and_symlinks_are_checked(self):
        self.write('README.md','[wrong case](docs/design/Interface.md)\n[escape](../outside.md)\n')
        link=self.root/'docs/linked.md'; link.symlink_to(self.root/'README.md'); result=g.documentation(self.root)
        self.assertFalse(result['Passed']); self.assertTrue(any('linked-path' in x for x in result['Diagnostics'])); self.assertEqual(sum('link-target' in x for x in result['Diagnostics']),2)

    def test_complete_gate_rejects_live_nested_list_links(self):
        (self.root/'tools').mkdir(); (self.root/'tools/verify.json').write_text('{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}')
        self.write('docs/NEXT.md','- Resource list\n    - [Missing page](does-not-exist.md)\n')
        result=g.verify(self.root)
        self.assertFalse(result['Passed'],result)
        self.assertTrue(any('does-not-exist.md' in item and 'docs/NEXT.md:2:' in item for item in result['Diagnostics']),result)

    def test_complete_gate_checks_all_commonmark_link_forms(self):
        self.write('tools/verify.json','{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}')
        cases = {
            'wrapped': 'See [the broken\nnote](docs/missing.md).\n',
            'badge': '[![badge](docs/DESIGN.md)](docs/missing.md)\n',
            'escaped bracket': '[a\\]b](docs/missing.md)\n',
            'nested brackets': '[a [b] c](docs/missing.md)\n',
            'formatted collapsed reference': '[*Foo*][]\n\n[*foo*]: docs/missing.md\n',
            'formatted shortcut reference': '[*Foo*]\n\n[*foo*]: docs/missing.md\n',
            'unclosed inline HTML comment': 'Compare a <!-- b in prose.\n\n[bad](docs/missing.md)\n',
        }
        for label, text in cases.items():
            with self.subTest(label=label):
                self.write('README.md',text)
                result=g.verify(self.root)
                self.assertFalse(result['Passed'],result)
                self.assertTrue(any('link-target' in item and 'docs/missing.md' in item for item in result['Diagnostics']),result)

    def test_wrapped_markdown_judgement_links_keep_their_label_and_metadata(self):
        path=self.root/'docs/JUDGEMENTS.md'; original=path.read_text()
        target='judgements/interface.md#focus-is-visible'
        for link in ('[Focus is visible](\n  '+target+')','[Focus is visible]('+target+'\n  )','[Focus is\nvisible]('+target+')'):
            with self.subTest(link=link):
                path.write_text(original.replace('[[judgements/interface#Focus is visible|Focus is visible]]',link))
                result=g.documentation(self.root)
                self.assertTrue(result['Passed'],result)

    def test_unicode_separators_preserve_judgement_source_lines(self):
        topic=self.root/'docs/judgements/interface.md'; original=topic.read_text()
        index=self.root/'docs/JUDGEMENTS.md'; original_index=index.read_text()
        for separator in ('\u2028','\u2029','\x85','\v','\f','\x1c','\x1d','\x1e'):
            with self.subTest(separator=repr(separator)):
                topic.write_text(original.replace('Body.','Pasted left'+separator+'right.')+'\n### Second record\n*Judged 2024-03-01, on Linux desktop.*\nBody.\n')
                index.write_text(original_index+'Pasted left'+separator+'right.\n- [Second record](judgements/interface.md#second-record) — Judged 2024-03-01, on Linux desktop\n')
                result=g.documentation(self.root)
                self.assertTrue(result['Passed'],result)

    def test_complete_gate_checks_links_nested_in_image_alt_text(self):
        self.write('tools/verify.json','{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}')
        cases=(
            ('![alt [x](docs/missing.md)](docs/DESIGN.md)\n',1),
            ('![alt\n[x](docs/missing.md)](docs/DESIGN.md)\n',2),
            ('![outer ![inner [x](docs/missing.md)](docs/DESIGN.md)](docs/DESIGN.md)\n',1),
            ('![alt [x][ref]](docs/DESIGN.md)\n\n[ref]: docs/missing.md\n',1),
        )
        for text,line in cases:
            with self.subTest(text=text):
                self.write('README.md',text)
                result=g.verify(self.root)
                self.assertFalse(result['Passed'],result)
                self.assertTrue(any('README.md:'+str(line)+':' in item and 'docs/missing.md' in item for item in result['Diagnostics']),result)

    def test_html_comments_do_not_hide_links_outside_their_commonmark_scope(self):
        self.write('tools/verify.json','{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}')
        cases=(
            ('- <!-- note\n- [bad](docs/missing.md)\n',2),
            ('> <!-- note\n\n[bad](docs/missing.md)\n',3),
            ('Text <!-- a\n\n[bad](docs/missing.md)\n\nmore --> end\n',3),
        )
        for text,line in cases:
            with self.subTest(text=text):
                self.write('README.md',text)
                result=g.verify(self.root)
                self.assertFalse(result['Passed'],result)
                self.assertTrue(any('README.md:'+str(line)+':' in item and 'docs/missing.md' in item for item in result['Diagnostics']),result)

    def test_unicode_whitespace_trim_cannot_turn_code_into_an_obsidian_comment(self):
        self.write('tools/verify.json','{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}')
        for space in ('\u00a0','\u2028','\u3000'):
            for prefix,continuation in ((space*3+'\n','Write `%%` to start a comment.\n'),('- '+space+'\n','  Write `%%` to start a comment.\n'),('> '+space+'\n','> Write `%%` to start a comment.\n'),(space*3+'\n','Write `%%` to start a comment.\n---\n')):
                with self.subTest(prefix=repr(prefix),continuation=continuation):
                    text=prefix+continuation+'\n[bad](docs/missing.md)\n'
                    self.write('README.md',text)
                    result=g.verify(self.root)
                    self.assertFalse(result['Passed'],result)
                    line=text[:text.index('[bad]')].count('\n')+1
                    self.assertTrue(any('README.md:'+str(line)+':' in item and 'docs/missing.md' in item for item in result['Diagnostics']),result)

    def test_tab_expansion_does_not_hide_a_wiki_link_beside_code(self):
        self.write('docs/NEXT.md','- item\n\tmore `x`[[missing-note]] end\n')
        result=g.documentation(self.root)
        self.assertFalse(result['Passed'],result)
        self.assertTrue(any('docs/NEXT.md:2:' in item and 'missing-note' in item for item in result['Diagnostics']),result)

    def test_unicode_trimmed_index_paragraph_keeps_its_metadata_line(self):
        path=self.root/'docs/JUDGEMENTS.md'
        path.write_text(path.read_text().replace('- [[judgements/interface#Focus is visible|Focus is visible]]','\u00a0\u00a0\n[Focus is visible](judgements/interface.md#focus-is-visible)'))
        result=g.documentation(self.root)
        self.assertTrue(result['Passed'],result)

    def test_html_comment_exclusion_preserves_the_surrounding_list_structure(self):
        self.write('tools/verify.json','{"schemaVersion":1,"preset":"foundation","requiredChecks":["documentation"]}')
        for indent in ('    ','\t'):
            with self.subTest(indent=repr(indent)):
                self.write('README.md','- <!--\n  -->\n'+indent+'[bad](docs/missing.md)\n')
                result=g.verify(self.root)
                self.assertFalse(result['Passed'],result)
                self.assertTrue(any('README.md:3:' in item and 'docs/missing.md' in item for item in result['Diagnostics']),result)

if __name__=='__main__': unittest.main()
