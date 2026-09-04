import pathlib
import unittest


SOURCE = pathlib.Path(__file__).resolve().parents[2] / "ios-kiosk/src/Core/DBFrostedBlur.m"


class FrostedBlurOrientationContractTests(unittest.TestCase):
    def test_cpu_and_gpu_normalize_bottom_up_rows_at_one_shared_boundary(self):
        source = SOURCE.read_text()
        boundary = source.index("static UIImage *DBImageFromBottomUpPixels")
        flip = source.index("DBFlipPixelRows(pixels, width, height);", boundary)
        image = source.index("return DBImageFromPixels(pixels, width, height);", flip)
        gpu = source.index("static UIImage *DBGpuBlur")
        cpu = source.index("static UIImage *DBCpuBlur")
        gpu_output = source.index("return DBImageFromBottomUpPixels(output, width, height);", gpu)
        cpu_output = source.index("return DBImageFromBottomUpPixels(output, width, height);", cpu)
        self.assertLess(boundary, flip)
        self.assertLess(flip, image)
        self.assertLess(gpu, gpu_output)
        self.assertLess(cpu, cpu_output)

    def test_large_radius_bypasses_sparse_gpu_sampling(self):
        source = SOURCE.read_text()
        selection = source.index("if (DBFrostedBlurUsesGPUForRadius(radius))")
        gpu = source.index("blurred = DBGpuBlur", selection)
        cpu = source.index("if (!blurred) blurred = DBCpuBlur", gpu)
        self.assertLess(selection, gpu)
        self.assertLess(gpu, cpu)


if __name__ == "__main__":
    unittest.main()
