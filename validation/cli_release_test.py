"""Release lookup and historical artifact promotion contracts."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'tools'))
import cli_release as release


class ReleaseLookup(unittest.TestCase):
    def test_published_release_uses_tag_lookup(self):
        value=dict(id=4,tag_name='v1.2.3',draft=False,assets=[])
        with mock.patch.object(release,'api',return_value=json.dumps(value)),mock.patch.object(release,'gh') as gh:
            self.assertEqual(release.release_info('v1.2.3'),value)
            gh.assert_not_called()

    def test_authenticated_draft_lookup_uses_id(self):
        value=dict(id=7,tag_name='v1.2.3',draft=True,assets=[])
        with mock.patch.object(release,'api',side_effect=[None,json.dumps(value)]) as api,\
             mock.patch.object(release,'gh',return_value=json.dumps([[value]])):
            self.assertEqual(release.release_info('v1.2.3'),value)
            self.assertTrue(api.call_args.args[0].endswith('/releases/7'))

    def test_paginated_draft_lookup(self):
        value=dict(id=7,tag_name='v1.2.3',draft=True,assets=[])
        with mock.patch.object(release,'api',side_effect=[None,json.dumps(value)]),\
             mock.patch.object(release,'gh',return_value=json.dumps([[dict(id=1,tag_name='other')],[value]])):
            self.assertEqual(release.release_info('v1.2.3'),value)

    def test_absent_release(self):
        with mock.patch.object(release,'api',return_value=None),\
             mock.patch.object(release,'gh',return_value='[[]]'):
            self.assertIsNone(release.release_info('v1.2.3'))

    def test_duplicate_drafts_are_rejected(self):
        with mock.patch.object(release,'api',return_value=None),\
             mock.patch.object(release,'gh',return_value=json.dumps([[dict(id=1,tag_name='v1.2.3'),dict(id=2,tag_name='v1.2.3')]])):
            with self.assertRaisesRegex(ValueError,'multiple release drafts'):
                release.release_info('v1.2.3')

    def test_source_commit_must_be_full_hash(self):
        with self.assertRaises(ValueError):
            release.source_file('main','moon.mod')

    def test_source_bytes_come_from_git_object(self):
        with tempfile.TemporaryDirectory(prefix='moonground-release-source-') as temporary:
            directory=Path(temporary)
            def git(*args):
                return subprocess.check_output(['git']+list(args),cwd=str(directory))
            git('init','--quiet')
            original=b'version = "1.2.3"\n'
            for content in [original,b'version = "2.0.0"\n']:
                (directory/'moon.mod').write_bytes(content)
                git('add','moon.mod')
                git('-c','user.name=Release test','-c','user.email=test@example.invalid',
                    'commit','--quiet','-m','fixture version')
                if content==original:
                    commit=git('rev-parse','HEAD').decode().strip()
            self.assertNotEqual(commit,git('rev-parse','HEAD').decode().strip())
            with mock.patch.object(release,'ROOT',directory),\
                 mock.patch.dict(os.environ,{'GITHUB_REPOSITORY':release.manager.REPOSITORY}):
                self.assertEqual(release.source_file(commit,'moon.mod'),original)
                release.source('1.2.3',commit)
                with self.assertRaisesRegex(ValueError,'source moon.mod'):
                    release.source('2.0.0',commit)


if __name__=='__main__':
    unittest.main()
