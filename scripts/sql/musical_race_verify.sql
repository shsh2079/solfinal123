-- 뮤지컬 회차에서 유저1·2 동시 요청 후 결과 확인
--
-- 절차
--  1) users 에 user1, user2 존재 확인
--  2) python3 ../scripts/sqs_race_two_users_musical.py --user1 1 --user2 2
--  3) 워커 소비 후 이 파일에서 @show_id, @u1, @u2 맞춰 실행
--
-- 참고: 시드 공연명은 '뮤지컬 <별이 빛나는 밤>' (가장 가까운 회차 = 2026-06-01)
-- @show_id 는 해당 회차로 설정

SET @show_id := 0;
SET @u1 := 1;
SET @u2 := 2;

-- 회차별 예매(유저 누가 몇 건 성공했는지)
SELECT user_id, COUNT(*) AS booking_count
FROM concert_booking
WHERE show_id = @show_id
GROUP BY user_id
ORDER BY user_id;

-- 좌석당 점유 1건인지(겹침 없음)
SELECT 'duplicate_active_seats' AS metric, COUNT(*) AS bad_groups
FROM (
  SELECT seat_row_no, seat_col_no, COUNT(*) AS c
  FROM concert_booking_seats
  WHERE show_id = @show_id AND status = 'ACTIVE'
  GROUP BY seat_row_no, seat_col_no
  HAVING c > 1
) t;

-- 최근 예매 좌석 목록(누가 어떤 좌석을 가졌는지)
SELECT cb.user_id, cb.booking_id, cbs.seat_row_no, cbs.seat_col_no, cb.created_at
FROM concert_booking cb
JOIN concert_booking_seats cbs ON cbs.booking_id = cb.booking_id AND cbs.show_id = cb.show_id
WHERE cb.show_id = @show_id AND cbs.status = 'ACTIVE'
ORDER BY cb.created_at DESC, cb.booking_id DESC
LIMIT 30;
