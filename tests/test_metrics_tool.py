#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from summarize_metrics import summarize
class Metrics(unittest.TestCase):
    def row(self):
        return dict(elapsed_ms=2000,capture_calls=10,captures=8,capture_ms=40,
          pipeline_calls=16,pipeline_ms=80,queued_batches=12,queued_bytes=500000,
          queue_rejects=1,acks=10,ack_total_ms=200,security_rejects=2)
    def test_averages(self):
        s=summarize([self.row()]);self.assertEqual(s['mean_capture_call_ms'],4)
        self.assertEqual(s['mean_profile_pipeline_ms'],5);self.assertEqual(s['queued_payload_mbps'],2)
        self.assertEqual(s['mean_ack_ms'],20)
        self.assertEqual(s['capture_calls_per_second'],5)
        self.assertEqual(s['acked_batches_per_second'],5)
    def test_missing_and_negative(self):
        with self.assertRaises(ValueError):summarize([])
        r=self.row();r['captures']=-1
        with self.assertRaises(ValueError):summarize([r])
    def test_counter_reset(self):
        r=self.row();n=self.row();n['queued_bytes']=1
        with self.assertRaises(ValueError):summarize([r,n])
    def test_no_ack(self):
        r=self.row();r['acks']=0;r['ack_total_ms']=0
        self.assertIsNone(summarize([r])['mean_ack_ms'])
if __name__=='__main__':unittest.main(verbosity=2)
