-- 콘서트 대량 적재(예: 5만석 회차에 1만 건) 후 DB 정합성 확인
--
-- 절차 요약
--  1) 적재 전: show_id·total_count·유도 잔여(아래 SELECT 패턴) 확인
--  2) 전송 (terraform/ 에서): python3 ../scripts/sqs_load_real_concert.py -n 10000
--     (워커가 모두 소비할 때까지 대기)
--  3) 보낸 건수 N 이면 기대: booking_seats_active = N, remain = 초기 - N, duplicate_active_seats = 0
--  4) 아래 @show_id 설정 후 이 파일 실행
--
-- 사용 전: 아래 @show_id 를 해당 concert_shows.show_id 로 바꾼다.
--   SELECT show_id, show_date, total_count (잔여는 sold_seats 로부터 유도)
--   FROM concert_shows cs
--   JOIN concerts c ON c.concert_id = cs.concert_id
--   WHERE c.title = '2026 봄 페스티벌 LIVE - 5만석'
--   ORDER BY show_date;

SET @show_id := 0;

-- 예매 건수
SELECT 'concert_booking_rows' AS metric, COUNT(*) AS cnt
FROM concert_booking WHERE show_id = @show_id;

-- ACTIVE 좌석 점유(1좌석/건이면 booking 건수와 같아야 함)
SELECT 'booking_seats_active' AS metric, COUNT(*) AS cnt
FROM concert_booking_seats
WHERE show_id = @show_id AND status = 'ACTIVE';

-- 같은 좌석에 ACTIVE 두 줄 이상 = 중복 예매 버그
SELECT 'duplicate_active_seats' AS metric, COUNT(*) AS bad_groups
FROM (
  SELECT seat_row_no, seat_col_no, COUNT(*) AS c
  FROM concert_booking_seats
  WHERE show_id = @show_id AND status = 'ACTIVE'
  GROUP BY seat_row_no, seat_col_no
  HAVING c > 1
) t;

-- 잔여석: ACTIVE 좌석 수 기준 유도값(컬럼 remain_count 는 워커가 갱신하지 않음)
SELECT show_id, total_count,
       GREATEST(0, total_count - IFNULL((
         SELECT COUNT(*) FROM concert_booking_seats
         WHERE show_id = @show_id AND status = 'ACTIVE'
       ), 0)) AS remain_derived,
       remain_count AS remain_column_legacy,
       (SELECT COUNT(*) FROM concert_booking_seats
        WHERE show_id = @show_id AND status = 'ACTIVE') AS sold_seats
FROM concert_shows WHERE show_id = @show_id;
