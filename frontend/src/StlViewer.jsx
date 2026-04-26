import { useEffect, useRef, useState } from "react";
import * as THREE from "three";
import { STLLoader } from "three/examples/jsm/loaders/STLLoader.js";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";

function useTheme() {
  const [theme, setTheme] = useState(
    () => document.documentElement.dataset.theme || "light",
  );
  useEffect(() => {
    const update = () =>
      setTheme(document.documentElement.dataset.theme || "light");
    const observer = new MutationObserver(update);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });
    return () => observer.disconnect();
  }, []);
  return theme;
}

function readVar(name) {
  return getComputedStyle(document.documentElement)
    .getPropertyValue(name)
    .trim();
}

export default function StlViewer({ url }) {
  const containerRef = useRef(null);
  const theme = useTheme();

  useEffect(() => {
    if (!url || !containerRef.current) return;

    const container = containerRef.current;
    const width = container.clientWidth;
    const height = 500;

    const scene = new THREE.Scene();
    scene.background = new THREE.Color(readVar("--uc-bg") || "#fdfaff");

    const camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 5000);
    camera.position.set(80, 80, 120);

    const renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setPixelRatio(window.devicePixelRatio);
    renderer.setSize(width, height);
    container.appendChild(renderer.domElement);

    // Soft ambient + directional key light from above
    const ambient = new THREE.AmbientLight(0xffffff, 0.55);
    scene.add(ambient);

    const key = new THREE.DirectionalLight(0xffffff, 0.85);
    key.position.set(120, 200, 120);
    scene.add(key);

    // Pink rim light from behind for the dreamy edge glow
    const rim = new THREE.DirectionalLight(0xffb3f8, 0.7);
    rim.position.set(-80, 60, -120);
    scene.add(rim);

    // Subtle indigo fill from below to keep shadows pastel, never black
    const fill = new THREE.DirectionalLight(0xa3a4f6, 0.25);
    fill.position.set(40, -80, 40);
    scene.add(fill);

    // Pastel grid floor — color from --uc-border (theme-aware)
    const gridColor = new THREE.Color(readVar("--uc-border") || "#e8dcfb");
    const grid = new THREE.GridHelper(400, 40, gridColor, gridColor);
    grid.material.transparent = true;
    grid.material.opacity = 0.7;
    scene.add(grid);

    const controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;

    let mesh = null;
    let cancelled = false;

    const loader = new STLLoader();
    loader.load(
      url,
      (geometry) => {
        if (cancelled) return;
        geometry.computeVertexNormals();
        geometry.center();

        const material = new THREE.MeshStandardMaterial({
          color: 0xcba3f6,
          metalness: 0.05,
          roughness: 0.55,
        });
        mesh = new THREE.Mesh(geometry, material);
        mesh.rotation.x = -Math.PI / 2;
        scene.add(mesh);

        const box = new THREE.Box3().setFromObject(mesh);
        const size = box.getSize(new THREE.Vector3()).length();
        const center = box.getCenter(new THREE.Vector3());

        controls.target.copy(center);
        const dist = size * 1.4;
        camera.position.copy(center).add(new THREE.Vector3(dist, dist * 0.8, dist));
        camera.near = size / 100;
        camera.far = size * 100;
        camera.updateProjectionMatrix();
        controls.update();
      },
      undefined,
      (err) => {
        console.error("STL load error", err);
      },
    );

    let frame;
    const animate = () => {
      frame = requestAnimationFrame(animate);
      controls.update();
      renderer.render(scene, camera);
    };
    animate();

    const onResize = () => {
      const w = container.clientWidth;
      camera.aspect = w / height;
      camera.updateProjectionMatrix();
      renderer.setSize(w, height);
    };
    window.addEventListener("resize", onResize);

    return () => {
      cancelled = true;
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", onResize);
      controls.dispose();
      if (mesh) {
        mesh.geometry.dispose();
        mesh.material.dispose();
      }
      renderer.dispose();
      if (renderer.domElement.parentNode === container) {
        container.removeChild(renderer.domElement);
      }
    };
  }, [url, theme]);

  return <div ref={containerRef} style={{ width: "100%", height: 500 }} />;
}
