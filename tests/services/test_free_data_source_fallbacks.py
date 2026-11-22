"""Regression coverage for free stock-list data-source fallbacks."""

from __future__ import annotations

import sys
import types

import pandas as pd

from app.services.data_sources.akshare_adapter import AKShareAdapter
from app.services.data_sources.baostock_adapter import BaoStockAdapter


def test_akshare_stock_list_skips_removed_endpoints(monkeypatch):
    """A removed optional endpoint must not prevent remaining fallbacks."""
    fake_akshare = types.SimpleNamespace(
        stock_info_a_code_name=lambda: pd.DataFrame(
            {"code": ["000001"], "name": ["平安银行"]}
        )
    )
    monkeypatch.setitem(sys.modules, "akshare", fake_akshare)

    result = AKShareAdapter().get_stock_list()

    assert result is not None
    assert result.loc[0, "symbol"] == "000001"
    assert result.loc[0, "ts_code"] == "000001.SZ"


class _FakeBaoResult:
    def __init__(self, fields, rows):
        self.error_code = "0"
        self.error_msg = ""
        self.fields = fields
        self._rows = iter(rows)
        self._current = None

    def next(self):
        try:
            self._current = next(self._rows)
            return True
        except StopIteration:
            return False

    def get_row_data(self):
        return self._current


def test_baostock_default_stock_list_skips_slow_industry_query(monkeypatch):
    """The synchronization path should return stock basics without industry I/O."""
    basic = _FakeBaoResult(
        ["code", "code_name", "ipoDate", "outDate", "type", "status"],
        [["sz.000001", "平安银行", "1991-04-03", "", "1", "1"]],
    )

    fake_baostock = types.SimpleNamespace(
        login=lambda: types.SimpleNamespace(error_code="0", error_msg=""),
        logout=lambda: None,
        query_stock_basic=lambda: basic,
        query_stock_industry=lambda: (_ for _ in ()).throw(
            AssertionError("default stock-list retrieval must not query industry")
        ),
    )
    monkeypatch.setitem(sys.modules, "baostock", fake_baostock)

    result = BaoStockAdapter().get_stock_list()

    assert result is not None
    assert result.loc[0, "symbol"] == "000001"
    assert result.loc[0, "industry"] == ""
