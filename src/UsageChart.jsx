import React, { useEffect, useRef } from 'react';
import * as d3 from 'd3';

// D3 owns the SVG marks and scales; React owns the surrounding component lifecycle.
export default function UsageChart({ data }) {
  const svgRef = useRef(null);
  useEffect(() => {
    const svg = d3.select(svgRef.current);
    svg.selectAll('*').remove();
    const width = 620;
    const height = 210;
    const margin = { top: 14, right: 18, bottom: 34, left: 48 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;
    const values = data?.length ? data : [
      { day: 'Mon', input_output_tokens: 0 }, { day: 'Tue', input_output_tokens: 0 },
      { day: 'Wed', input_output_tokens: 0 }, { day: 'Thu', input_output_tokens: 0 },
      { day: 'Fri', input_output_tokens: 0 }, { day: 'Sat', input_output_tokens: 0 },
      { day: 'Sun', input_output_tokens: 0 },
    ];
    const x = d3.scaleBand().domain(values.map((item) => item.day)).range([0, innerWidth]).padding(0.32);
    const y = d3.scaleLinear().domain([0, Math.max(1, d3.max(values, (item) => item.input_output_tokens) || 1)]).nice().range([innerHeight, 0]);
    const group = svg.attr('viewBox', `0 0 ${width} ${height}`).append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);
    group.append('g').call(d3.axisLeft(y).ticks(4).tickFormat(d3.format('~s')))
      .call((axis) => axis.selectAll('text').attr('fill', '#92a2b7'))
      .call((axis) => axis.selectAll('line,path').attr('stroke', '#2a3a4d'));
    group.append('g').attr('transform', `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x).tickSize(0))
      .call((axis) => axis.selectAll('text').attr('fill', '#92a2b7').attr('dy', '1.5em'))
      .call((axis) => axis.select('.domain').attr('stroke', '#2a3a4d'));
    group.selectAll('rect.bar').data(values).join('rect')
      .attr('class', 'bar').attr('x', (item) => x(item.day))
      .attr('y', (item) => y(item.input_output_tokens)).attr('width', x.bandwidth())
      .attr('height', (item) => innerHeight - y(item.input_output_tokens))
      .attr('rx', 5).attr('fill', '#71d5bd');
    group.selectAll('text.value').data(values.filter((item) => item.input_output_tokens > 0)).join('text')
      .attr('class', 'value').attr('x', (item) => x(item.day) + x.bandwidth() / 2)
      .attr('y', (item) => y(item.input_output_tokens) - 7).attr('text-anchor', 'middle')
      .attr('fill', '#dce8f5').attr('font-size', 10).text((item) => d3.format('~s')(item.input_output_tokens));
  }, [data]);
  return <svg className="usage-chart" ref={svgRef} role="img" aria-label="Daily reported input plus output token counters" />;
}
