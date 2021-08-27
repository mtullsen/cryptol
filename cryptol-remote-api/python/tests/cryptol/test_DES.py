import unittest
from pathlib import Path
import unittest
import cryptol
from cryptol.cryptoltypes import CryptolApplication, CryptolLiteral
from cryptol.bitvector import BV


class TestDES(unittest.TestCase):
    def test_DES(self):
        c = cryptol.connect_sync(verify=False)
        c.load_file(str(Path('tests','cryptol','test-files','examples','DEStest.cry')))

        # we can run the test suite as indended...
        # vkres = c.eval('vktest DES')
        # self.assertTrue(all(passed for (_,_,passed) in vkres))
        # vtres = c.eval('vttest DES')
        # self.assertTrue(all(passed for (_,_,passed) in vtres))
        # kares = c.eval('katest DES')
        # self.assertTrue(all(passed for (_,_,passed) in kares))

        # ...but we can also do it manually, using the python bindings more
        def test(key, pt0, ct0):
            ct1 = c.call('DES.encrypt', key, pt0)
            pt1 = c.call('DES.decrypt', key, ct0)
            self.assertEqual(ct0, ct1)
            self.assertEqual(pt0, pt1)

        # vktest
        vk = c.eval('vk')
        pt0 = BV(size=64, value=0)
        for (key, ct0) in vk:
            test(key, pt0, ct0)

        # vttest
        vt = c.eval('vt')
        key = BV(size=64, value=0x0101010101010101)
        for (pt0, ct0) in vt:
            test(key, pt0, ct0)

        # katest
        ka = c.eval('ka')
        for (key, pt0, ct0) in ka:
            test(key, pt0, ct0)


if __name__ == "__main__":
    unittest.main()
