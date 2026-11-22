"""Create Tushare clients with an optional custom API endpoint."""


def create_tushare_client(token):
    import tushare as ts
    from app.core.config import settings

    client = ts.pro_api(token)
    api_url = settings.TUSHARE_API_URL.strip()
    if api_url:
        client._DataApi__http_url = api_url
    return client
