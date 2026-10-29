begin;
-- Allocate a negative adjustment against the amounts remaining after discount.
-- Separate allocation against gross could over-credit a one-cent line even when
-- the invoice as a whole stayed nonnegative.
do $$declare definition text;begin
 definition:=pg_get_functiondef('binderclip.practical_snapshot(uuid,text,jsonb)'::regprocedure);
 definition:=replace(definition,
 'allocated_adjustment:=case when gross=0 then 0 else round(adjustment_value*running/gross,2)-prior_adjustment end;',
 'allocated_adjustment:=case when gross=0 then 0 when adjustment_value<0 then round(adjustment_value*(running-prior_discount-allocated_discount)/(gross-discount_value),2)-prior_adjustment else round(adjustment_value*running/gross,2)-prior_adjustment end;');
 execute definition;
end $$;
commit;
