let count = 0;
document.getElementById("increase").addEventListener("click", () => {
    count++;
    document.getElementById("count").textContent = count;
});
