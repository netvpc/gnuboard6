# gnuboard6

gnuboard6 자체의 의존성 문제로 Dockerfile (linux/arm/v7) 지저분 합니다.
참고 바랍니다.

```Dockerfile
RUN /venv/bin/python3 -m pip install --extra-index-url=https://pypi.org/simple/ --extra-index-url=https://www.piwheels.org/simple/ --no-cache-dir -r requirements.txt
```